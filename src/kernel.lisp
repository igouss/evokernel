;;;; kernel.lisp — the engine.
;;;;
;;;;   (defun run (goal)
;;;;     (loop until (invariants)                       ; done when the heap says so
;;;;           for form = (ask-model (observe goal))    ; re-read, then one form
;;;;           do (assert (not (locked-p form)))        ; the kernel is not the world
;;;;              (let ((snap (snapshot)))
;;;;                (restart-case (eval form)           ; menu stays live until picked
;;;;                  (abort () (restore snap))))))     ; bad commit, old heap, next turn
;;;;
;;;; Everything else in this file exists to make those eight lines true.

(defpackage :world
  (:use :cl)
  (:documentation "The sandbox. Everything the model grows lives here. Nothing else does."))

(defpackage :evo.kernel
  (:use :cl)
  (:export #:*state* #:*definitions* #:*properties* #:*budget* #:*generation* #:*revisions*
           #:*model* #:*auto-abort* #:*eval-timeout* #:*project-root* #:*log*
           #:defgoal #:find-goal #:list-goals #:goal #:goal-name #:goal-description
           #:defproperty #:property-report
           #:run #:observe #:ask-model #:locked-p #:snapshot #:restore #:invariants #:goal-satisfied-p
           #:commit-revision #:rollback #:revision #:revision-number #:revision-id #:revision-generation #:revision-file
           #:verify-fresh #:verify-in-process #:status-line #:evaluate #:seed-world #:freeze-base
           #:locked-form #:invariant-violation #:budget-exhausted))

(in-package :evo.kernel)

;;; ------------------------------------------------------------------
;;; World state
;;; ------------------------------------------------------------------

(defvar world::*state* (make-hash-table :test #'equal)
  "The data half of the world. Keyword keys, printable values.")

(defvar *definitions* '()
  "Ordered alist (symbol . source-form) of every definition the model grew. The
   image is the truth at runtime; this list is what gets dumped to git.")

(defvar *properties* '()
  "Safety invariants: list of (name . thunk). Must hold after EVERY accepted form,
   regardless of goal. The heap says so, or the heap gets restored.")

(defvar *revisions* '() "Accepted revisions, newest first.")
(defvar *current-revision* nil "The revision the live heap currently corresponds to (or NIL if it has drifted).")
(defvar *generation* 0)
(defvar *budget* 200000 "Fuel. Tokens. When it hits zero the engine stops.")
(defvar *tokens-burned* 0)
(defvar *model* nil "Function (system-prompt messages) -> (values text tokens-used).")
(defvar *auto-abort* t
  "T: an error during eval auto-selects the ABORT restart (headless). NIL: you get the
   restart menu in the debugger and pick it yourself. Menu stays live until picked.")
(defvar *project-root* (or (ignore-errors (truename (merge-pathnames "../" (directory-namestring *load-truename*))))
                           *default-pathname-defaults*))
(defvar *log* *standard-output*)
(defvar *feedback* '() "Recent (turn . message) failures fed back to the model.")
(defvar *eval-timeout* nil "Seconds a model form, example or property check may run; NIL = no limit.")
(defvar *max-feedback* 6)
(defvar *base-snap* nil "Snapshot of the world right after seed + goals loaded. Rollback starts here.")

(define-condition locked-form (error)
  ((form :initarg :form :reader locked-form-form)
   (why :initarg :why :reader locked-form-why))
  (:report (lambda (c s) (format s "locked: ~a" (locked-form-why c)))))

(define-condition invariant-violation (error)
  ((failures :initarg :failures :reader invariant-violation-failures))
  (:report (lambda (c s) (format s "invariant violated: ~{~a~^, ~}" (invariant-violation-failures c)))))

(define-condition budget-exhausted (error) ()
  (:report "budget exhausted — insert more tokens"))

(defun logf (fmt &rest args)
  (apply #'format *log* fmt args)
  (terpri *log*)
  (finish-output *log*))

;;; ------------------------------------------------------------------
;;; The sandbox fence: "the kernel is not the world"
;;; ------------------------------------------------------------------

(defparameter *locked-packages*
  '(:evo.kernel :evo.json :evo.model :evo.repl :sb-ext :sb-sys :sb-alien :sb-unix :sb-impl
    :sb-thread :sb-posix :sb-int :sb-kernel :sb-vm :sb-c :asdf :uiop)
  "Any symbol from one of these packages in a model form locks it.")

(defparameter *locked-symbols*
  '(open with-open-file load compile-file delete-file rename-file delete-package
    defpackage in-package eval compile sleep ed dribble room
    make-package rename-package unintern intern)
  "CL symbols that reach outside the heap, or let the model reach back into the kernel.")

(defparameter *definer-heads* '(defun defmacro defvar defparameter defconstant defgeneric defmethod
                                defstruct defclass deftype define-condition defsetf))

(defvar *goal-forbidden* '() "Per-goal extra forbidden symbols, bound during RUN.")

(defun walk-symbols (form fn)
  (cond ((symbolp form) (funcall fn form))
        ((consp form) (walk-symbols (car form) fn) (walk-symbols (cdr form) fn))
        ((vectorp form) (map nil (lambda (x) (walk-symbols x fn)) form))
        (t nil)))

(defun defined-name (form)
  "If FORM is a definition, return the symbol it defines."
  (when (and (consp form) (member (car form) *definer-heads*) (consp (cdr form)))
    (let ((n (second form)))
      (cond ((symbolp n) n)
            ((and (consp n) (eq (car n) 'setf) (symbolp (second n))) (second n))
            ((consp n) (car n))        ; defstruct (name opts...)
            (t nil)))))

(defun locked-p (form)
  "Return a reason string if FORM may not be evaluated, else NIL."
  (let ((world (find-package :world)) (reason nil))
    (block scan
      (walk-symbols
       form
       (lambda (s)
         (let ((pkg (symbol-package s)))
           (cond ((and pkg (member (intern (package-name pkg) :keyword) *locked-packages*))
                  (setf reason (format nil "symbol ~s belongs to the kernel, not the world" s))
                  (return-from scan))
                 ((member s *locked-symbols*)
                  (setf reason (format nil "~s reaches outside the heap" s))
                  (return-from scan))
                 ((member s *goal-forbidden*)
                  (setf reason (format nil "~s is forbidden by the current goal" s))
                  (return-from scan))))))
      ;; redefining anything that isn't a WORLD symbol (e.g. CL:REVERSE) is locked
      (labels ((check-def (f)
                 (when (consp f)
                   (let ((n (defined-name f)))
                     (when (and n (not (eq (symbol-package n) world)))
                       (setf reason (format nil "cannot redefine ~s — not a WORLD symbol" n))
                       (return-from scan)))
                   (when (eq (car f) 'progn) (mapc #'check-def (cdr f))))))
        (check-def form)))
    reason))

;;; ------------------------------------------------------------------
;;; Snapshot / restore — the undo log for a live heap
;;; ------------------------------------------------------------------

(defun deep-copy (x)
  (typecase x
    (hash-table (let ((h (make-hash-table :test (hash-table-test x))))
                  (maphash (lambda (k v) (setf (gethash (deep-copy k) h) (deep-copy v))) x)
                  h))
    (cons (cons (deep-copy (car x)) (deep-copy (cdr x))))
    (string (copy-seq x))
    (vector (map 'vector #'deep-copy x))
    (t x)))

(defun world-symbols ()
  (let ((world (find-package :world)) (acc '()))
    (do-symbols (s world)
      (when (eq (symbol-package s) world) (push s acc)))
    acc))

(defstruct snap state definitions fbindings vbindings generation)

(defun snapshot ()
  (make-snap :state (deep-copy world::*state*)
             :definitions (copy-list *definitions*)
             :generation *generation*
             :fbindings (loop for s in (world-symbols)
                              when (fboundp s)
                                collect (list s (fdefinition s) (macro-function s)))
             :vbindings (loop for s in (world-symbols)
                              when (and (boundp s) (not (eq s 'world::*state*)))
                                collect (cons s (deep-copy (symbol-value s))))))

(defun restore (snap)
  ;; wipe every function/value the model may have grown since SNAP
  (dolist (s (world-symbols))
    (when (fboundp s) (fmakunbound s))
    (when (and (boundp s) (not (eq s 'world::*state*))) (makunbound s)))
  (loop for (s fn mac) in (snap-fbindings snap)
        do (if mac (setf (macro-function s) mac) (setf (fdefinition s) fn)))
  (loop for (s . v) in (snap-vbindings snap) do (setf (symbol-value s) v))
  (setf world::*state* (deep-copy (snap-state snap))
        *definitions* (copy-list (snap-definitions snap))
        *generation* (snap-generation snap))
  snap)

;;; ------------------------------------------------------------------
;;; Eval, with an optional leash
;;; ------------------------------------------------------------------

(defmacro with-leash (&body body)
  "BODY under *EVAL-TIMEOUT* seconds, or unbounded when it is NIL (SB-EXT:WITH-TIMEOUT rejects NIL)."
  `(flet ((leashed () ,@body))
     (if *eval-timeout* (sb-ext:with-timeout *eval-timeout* (leashed)) (leashed))))

(defun evaluate (form)
  "Evaluate FORM inside WORLD under WITH-LEASH. Records definitions."
  (let ((*package* (find-package :world)))
    (prog1 (with-leash (eval form))
      (record-definitions form))))

(defun record-definitions (form)
  (when (consp form)
    (if (eq (car form) 'progn)
        (mapc #'record-definitions (cdr form))
        (let ((n (defined-name form)))
          (when n
            (setf *definitions* (append (remove n *definitions* :key #'car) (list (cons n form)))))))))

(defun plist->table (plist)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on plist by #'cddr do (setf (gethash k h) v))
    h))

(defun table->plist (h)
  (let ((acc '()))
    (maphash (lambda (k v) (push v acc) (push k acc)) h)
    acc))

;;; ------------------------------------------------------------------
;;; Properties (safety invariants) and goals
;;; ------------------------------------------------------------------

(defmacro defproperty (name &body body)
  "A safety invariant. Must be true in every accepted heap."
  (let ((key (intern (string name) :keyword)))
    `(progn (setf *properties* (append (remove ,key *properties* :key #'car)
                                       (list (cons ,key (lambda () ,@body)))))
            ,key)))

(defun check-thunk (thunk)
  "Run THUNK -> (values pass-p detail)."
  (handler-case (with-leash
                  (let ((*package* (find-package :world)))
                    (values (and (funcall thunk) t) nil)))
    (serious-condition (c) (values nil (format nil "~a" c)))))

(defun property-report ()
  (loop for (name . thunk) in *properties*
        collect (multiple-value-bind (ok detail) (check-thunk thunk)
                  (list :name name :status (if ok :pass :fail) :detail detail))))

(defun invariants ()
  "T iff every safety property holds. (values ok failures)"
  (let ((failures (loop for r in (property-report)
                        when (eq (getf r :status) :fail)
                          collect (format nil "~a~@[ (~a)~]" (getf r :name) (getf r :detail)))))
    (values (null failures) failures)))

(defstruct goal
  name description
  (examples '())        ; list of (form expected) — evaluated in WORLD, compared with EQUAL
  property generator    ; property: (lambda (x) bool), generator: (lambda () x)
  (trials 1000)
  (forbidden '()))      ; symbols the model may not use for this goal

(defvar *goals* (make-hash-table :test #'equalp))

(defmacro defgoal (name &rest args)
  `(setf (gethash ,(string name) *goals*) (make-goal :name ,(string name) ,@args)))

(defun find-goal (name) (or (gethash (string name) *goals*) (error "no goal ~a" name)))
(defun list-goals () (loop for g being the hash-values of *goals* collect g))

(defun goal-satisfied-p (goal &key (max-failures 5))
  "(values ok failure-strings). Examples first, then generated trials."
  (let ((failures '()) (world (find-package :world)))
    (flet ((try (form expected)
             (multiple-value-bind (ok detail)
                 (handler-case (with-leash
                                 (let ((*package* world))
                                   (let ((got (eval form)))
                                     (if (equal got expected)
                                         (values t nil)
                                         (values nil (format nil "~s => ~s, expected ~s" form got expected))))))
                   (serious-condition (c) (values nil (format nil "~s signalled: ~a" form c))))
               (unless ok (push detail failures)))))
      (loop for (form expected) in (goal-examples goal)
            do (try form expected)
            while (< (length failures) max-failures))
      (when (and (null failures) (goal-property goal) (goal-generator goal))
        (loop repeat (goal-trials goal)
              for x = (funcall (goal-generator goal))
              do (multiple-value-bind (ok detail)
                     (handler-case (with-leash
                                     (let ((*package* world))
                                       (values (funcall (goal-property goal) x) nil)))
                       (serious-condition (c) (values nil (format nil "~a" c))))
                   (unless ok
                     (push (format nil "property failed on ~s~@[: ~a~]" x detail) failures)))
              while (< (length failures) max-failures))))
    (values (null failures) (nreverse failures))))

;;; ------------------------------------------------------------------
;;; Observe / ask — what the model sees, and how it answers
;;; ------------------------------------------------------------------

(defun definitions-source ()
  (with-output-to-string (s)
    (let ((*package* (find-package :world)) (*print-case* :downcase) (*print-right-margin* 100))
      (loop for (nil . form) in *definitions* do (pprint form s) (terpri s)))))

(defun observe (goal)
  "Re-read the heap. Returns a string: the whole world as the model will see it."
  (let ((*package* (find-package :world)) (*print-case* :downcase) (*print-pretty* nil))
    (with-output-to-string (s)
      (format s "== GOAL: ~a ==~%~a~%~%" (goal-name goal) (goal-description goal))
      (when (goal-forbidden goal)
        (format s "Forbidden symbols for this goal: ~{~s~^ ~}~%~%" (goal-forbidden goal)))
      (format s "== FIXED CASES (~d) ==~%" (length (goal-examples goal)))
      (loop for (form expected) in (goal-examples goal)
            do (format s "~s => ~s~%" form expected))
      (when (goal-generator goal)
        (format s "~%Plus ~d generated cases checked against a property you cannot see.~%" (goal-trials goal)))
      (format s "~%== STATE (*state*, generation ~d) ==~%~s~%" *generation* (table->plist world::*state*))
      (format s "~%== DEFINITIONS (~d) ==~%~a" (length *definitions*)
              (if *definitions* (definitions-source) "(none)~%"))
      (format s "~%== SAFETY PROPERTIES ==~%")
      (loop for r in (property-report)
            do (format s "~a: ~a~@[ ~a~]~%" (getf r :name) (getf r :status) (getf r :detail)))
      (multiple-value-bind (ok failures) (goal-satisfied-p goal)
        (format s "~%== GOAL STATUS ==~%~a~%" (if ok "SATISFIED" "NOT SATISFIED"))
        (dolist (f failures) (format s "  - ~a~%" f)))
      (when *feedback*
        (format s "~%== RECENT REJECTED TURNS ==~%")
        (loop for (turn . msg) in (reverse *feedback*) do (format s "turn ~d: ~a~%" turn msg)))
      (format s "~%Budget remaining: ~d tokens.~%" *budget*))))

(defparameter *system-prompt*
  "You are the hacker at the REPL of a live Common Lisp (SBCL) image. The image is the program.
Every reply you send is read by the Lisp reader in package WORLD and evaluated. One top-level
form per turn. Reply with ONLY the form, inside a ```lisp fence. No prose.

Rules the kernel enforces (a violation wastes the turn, the heap is restored):
- You may define or redefine only WORLD symbols. You cannot redefine CL functions.
- No I/O, no package ops, no EVAL/LOAD/COMPILE, no SB-* internals. The kernel is not the world.
- State lives in the hash table *state* (keyword keys). Mutate it with (setf (gethash :k *state*) v).
- Every safety property must still pass after your form. Otherwise it is rolled back.
- Wrap several definitions in one (progn ...) if you must, but prefer one defun per turn.
The loop ends when every fixed case and generated case of the goal passes. Read the GOAL STATUS
section: it tells you exactly which cases still fail. Fix those.")

(defun extract-form (text)
  "Pull the first Lisp form out of model text (fenced or bare). *read-eval* is off."
  (let* ((fence (search "```" text))
         (start (if fence
                    (let ((nl (position #\Newline text :start fence)))
                      (if nl (1+ nl) (+ fence 3)))
                    0))
         (end (if fence (or (search "```" text :start2 start) (length text)) (length text)))
         (body (subseq text start end))
         (paren (position #\( body)))
    (unless paren (error "model reply contains no form: ~a" (subseq text 0 (min 200 (length text)))))
    (let ((*package* (find-package :world)) (*read-eval* nil))
      (read-from-string body t nil :start paren))))

(defun ask-model (observation &key (system *system-prompt*))
  "Spend fuel, get one form. (values form raw-text)"
  (unless *model* (error "no model bound — set evo.kernel:*model*"))
  (when (<= *budget* 0) (error 'budget-exhausted))
  (multiple-value-bind (text tokens)
      (funcall *model* system (list (cons "user" observation)))
    (let ((tokens (or tokens 1)))
      (decf *budget* tokens)
      (incf *tokens-burned* tokens))
    (values (extract-form text) text)))

;;; ------------------------------------------------------------------
;;; RUN — the eight lines, with the plumbing exposed
;;; ------------------------------------------------------------------

(defun feedback (turn msg)
  (push (cons turn msg) *feedback*)
  (when (> (length *feedback*) *max-feedback*) (setf *feedback* (subseq *feedback* 0 *max-feedback*))))

(defun run (goal &key (max-turns 50) (commit t))
  "Drive the heap until GOAL and all safety properties hold. Returns the revision, or NIL."
  (let ((goal (if (goal-p goal) goal (find-goal goal)))
        (*goal-forbidden* nil)
        (*feedback* '()))
    (setf *goal-forbidden* (goal-forbidden goal))
    (logf "~&;; RUN ~a  budget=~d" (goal-name goal) *budget*)
    (loop for turn from 1 to max-turns
          until (and (invariants) (goal-satisfied-p goal))             ; done when the heap says so
          for form = (handler-case (ask-model (observe goal))         ; re-read, then one form
                       (budget-exhausted () (logf ";; out of fuel") (return nil))
                       (error (c) (feedback turn (format nil "unreadable reply: ~a" c)) nil))
          do (when form
               (logf ";; turn ~d  form: ~a" turn (let ((*package* (find-package :world)) (*print-case* :downcase))
                                                   (prin1-to-string form)))
               (let ((why (locked-p form)))
                 (if why
                     (progn (logf ";;   LOCKED: ~a" why) (feedback turn (format nil "locked: ~a" why)))
                     (let ((snap (snapshot)))
                       (restart-case                                   ; menu stays live until picked
                           (handler-bind ((sb-sys:interactive-interrupt
                                            (lambda (c) (declare (ignore c))
                                              (restore snap) (logf ";; interrupted, heap restored")
                                              (return-from run nil)))
                                          (serious-condition
                                            (lambda (c)
                                              (feedback turn (format nil "~a" c))
                                              (logf ";;   REJECTED: ~a" c)
                                              (when *auto-abort* (invoke-restart 'abort)))))
                             (evaluate form)
                             (multiple-value-bind (ok failures) (invariants)
                               (unless ok (error 'invariant-violation :failures failures)))
                             (incf *generation*)
                             (logf ";;   accepted -> generation ~d" *generation*))
                         (abort () :report "Restore the pre-turn heap and continue"
                           (restore snap)))))))                         ; bad commit, old heap, next turn
          finally (return))
    (multiple-value-bind (ok failures) (goal-satisfied-p goal)
      (cond ((and ok (invariants))
             (logf ";; GOAL ~a SATISFIED at generation ~d (~d tokens burned)"
                   (goal-name goal) *generation* *tokens-burned*)
             (if commit (commit-revision (goal-name goal)) t))
            (t (logf ";; stopped without satisfying ~a:~{~%;;   ~a~}" (goal-name goal) failures)
               nil)))))

;;; ------------------------------------------------------------------
;;; Revisions: the image is truth at runtime, git is truth across time
;;; ------------------------------------------------------------------

(defstruct revision number id generation goal definitions state created file sha)

(defun revision-dir () (merge-pathnames "revisions/" *project-root*))

(defun run-cmd (program args &key (dir *project-root*))
  "(values exit-code stdout)"
  (let* ((out (make-string-output-stream))
         (p (sb-ext:run-program program args :search t :output out :error out
                                             :directory (namestring dir))))
    (values (sb-ext:process-exit-code p) (string-trim '(#\Newline #\Space) (get-output-stream-string out)))))

(defun git (&rest args)
  (handler-case (run-cmd "git" args)
    (error (c) (values 127 (format nil "~a" c)))))

(defun write-revision-file (rev)
  (ensure-directories-exist (revision-dir))
  (let ((path (merge-pathnames (format nil "rev-~4,'0d.lisp" (revision-number rev)) (revision-dir))))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (let ((*package* (find-package :world)) (*print-case* :downcase) (*print-right-margin* 100))
        (format s ";;;; ~a~%;;;; generation ~d  goal ~a  ~a~%;;;; Grown by the model, dumped by the kernel. Diff me.~%~%"
                (revision-id rev) (revision-generation rev) (revision-goal rev) (revision-created rev))
        (format s "(in-package :world)~%~%")
        (format s ";;; --- state ---~%(setf *state* (evo.kernel::plist->table '~s))~%~%" (revision-state rev))
        (format s ";;; --- definitions ---~%")
        (loop for (nil . form) in (revision-definitions rev) do (pprint form s) (terpri s))
        (format s "~%;;; --- kernel bookkeeping ---~%")
        (format s "(evo.kernel::install-loaded-revision ~s ~d ~s '~s)~%"
                (revision-id rev) (revision-generation rev) (revision-goal rev)
                (mapcar #'car (revision-definitions rev)))))
    path))

(defun revision-from-forms (forms file)
  "The revision that FORMS, read from a revision FILE, describe. Nothing is evaluated: the trailing
   INSTALL-LOADED-REVISION form carries id, generation, goal and definition order, the SETF of
   *STATE* carries the state, and the definer forms carry the source."
  (let ((book (find-if (lambda (f) (and (consp f) (eq (car f) 'install-loaded-revision))) forms))
        (state (find-if (lambda (f) (and (consp f) (eq (car f) 'setf) (eq (second f) 'world::*state*))) forms))
        (sources (loop for f in forms for n = (defined-name f) when n collect (cons n f))))
    (unless (and book state) (error "~a is not a revision file" file))
    (destructuring-bind (id generation goal (quote-op names)) (rest book)
      (declare (ignore quote-op))
      (make-revision :number (parse-integer (pathname-name file) :start 4) :id id :generation generation
                     :goal goal :state (second (second (third state))) :created "on disk" :file file
                     :definitions (loop for n in names
                                        collect (or (assoc n sources)
                                                    (error "~a: no source for ~s" file n)))))))

(defun read-revision-file (file)
  (with-open-file (in file)
    (let ((*package* (find-package :world)) (*read-eval* nil))
      (revision-from-forms (loop for form = (read in nil in) until (eq form in) collect form)
                           (truename file)))))

(defun install-loaded-revision (id generation goal def-names)
  "Called at the end of a revision file when it is LOADed into a fresh image. The defuns are
   already live; re-read the file to recover their source so *definitions* (and therefore
   observe/dump/commit) keep working in this image. The arguments are data for
   REVISION-FROM-FORMS; the file itself is the source of truth."
  (declare (ignore id generation goal def-names))
  (let ((rev (read-revision-file *load-truename*)))
    (setf *generation* (revision-generation rev)
          *definitions* (copy-list (revision-definitions rev)))
    (push rev *revisions*)
    (setf *current-revision* rev)
    (logf ";; loaded revision ~a (generation ~d)" (revision-id rev) (revision-generation rev))
    (revision-id rev)))

(defun iso-now ()
  (multiple-value-bind (s m h d mo y) (get-decoded-time)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" y mo d h m s)))

(defun unsourced-functions ()
  "WORLD functions that exist in the heap but have no recorded source: created via
   (setf symbol-function) or similar, not via a definer form. A revision file could not reproduce
   them, so a heap containing them must not be committed."
  (let ((base (and *base-snap* (mapcar #'first (snap-fbindings *base-snap*)))))
    (loop for s in (world-symbols)
          when (and (fboundp s) (not (member s base)) (not (assoc s *definitions*)))
            collect s)))

(defun commit-revision (goal-name)
  "Freeze the current heap as a revision: in-memory, on disk, in git."
  (let ((orphans (unsourced-functions)))
    (when orphans
      (error "refusing to commit: ~{~s~^, ~} live in the heap with no recorded source — the file would lie" orphans)))
  (let* ((defs (copy-list *definitions*))
         (id (format nil "revision-~d-~d" (sxhash (definitions-source)) *generation*))
         (rev (make-revision :number (1+ (length *revisions*)) :id id :generation *generation*
                             :goal (string goal-name)
                             :definitions defs :state (table->plist world::*state*)
                             :created (iso-now))))
    (push rev *revisions*)
    (setf *current-revision* rev)
    (setf (revision-file rev) (write-revision-file rev))
    (multiple-value-bind (code out) (git "rev-parse" "--is-inside-work-tree")
      (declare (ignore out))
      (unless (zerop code) (git "init" "-q")))
    (git "add" (namestring (revision-file rev)))
    (multiple-value-bind (code staged) (git "diff" "--cached" "--name-only" "--" (namestring (revision-file rev)))
      (declare (ignore code))
      (if (zerop (length staged))
          (logf ";; ~a unchanged on disk, nothing to commit" (file-namestring (revision-file rev)))
          (multiple-value-bind (code out)
              (git "-c" "user.name=evokernel" "-c" "user.email=evokernel@localhost"
                   "commit" "-q" "--only" "-m"
                   (format nil "~a: ~a (generation ~d)" (revision-id rev) goal-name *generation*)
                   "--" (namestring (revision-file rev)))
            (if (zerop code)
                (multiple-value-bind (c sha) (git "rev-parse" "--short" "HEAD")
                  (declare (ignore c))
                  (setf (revision-sha rev) sha)
                  (logf ";; committed ~a -> ~a  git ~a" id (file-namestring (revision-file rev)) sha))
                (logf ";; wrote ~a (git commit failed: ~a)" (file-namestring (revision-file rev)) out)))))
    rev))

(defun find-revision (key)
  (cond ((revision-p key) key)
        ((integerp key) (or (find key *revisions* :key #'revision-number) (error "no revision #~d" key)))
        (t (or (find (string key) *revisions* :key #'revision-id :test #'string=)
               (find (string key) *revisions* :key #'revision-sha :test #'equal)
               (error "no revision ~a" key)))))

(defun rollback (key)
  "Replace the live heap with an accepted revision. Live. No restart."
  (let ((rev (find-revision key)) (base (snapshot)))
    (restore (or *base-snap* (error "no base snapshot — was load.lisp used?")))
    (setf world::*state* (plist->table (revision-state rev))
          *generation* (revision-generation rev))
    (handler-case
        (let ((*package* (find-package :world)))
          (loop for (nil . form) in (revision-definitions rev) do (evaluate form))
          (multiple-value-bind (ok failures) (invariants)
            (unless ok (error 'invariant-violation :failures failures))))
      (error (c)
        (restore base)
        (error "rollback to ~a failed, heap untouched: ~a" (revision-id rev) c)))
    (setf *current-revision* rev)
    (logf ";; rolled back to ~a (generation ~d)" (revision-id rev) *generation*)
    rev))

;;; ------------------------------------------------------------------
;;; Verification in a fresh process — the commit is real or it isn't
;;; ------------------------------------------------------------------

(defun verify-in-process (goal-name)
  "Run inside a fresh image after loading a revision file. Exit 0 iff goal + invariants pass."
  (let ((goal (find-goal goal-name)))
    (multiple-value-bind (ok failures) (goal-satisfied-p goal)
      (multiple-value-bind (inv inv-failures) (invariants)
        (logf ";; fresh-process verify ~a: goal ~a, invariants ~a" goal-name
              (if ok "PASS" "FAIL") (if inv "PASS" "FAIL"))
        (dolist (f (append failures inv-failures)) (logf ";;   ~a" f))
        (and ok inv)))))

(defun verify-fresh (key goal-name)
  "Spawn a brand new SBCL, load the kernel + goals + revision file, run the checks."
  (let* ((rev (find-revision key))
         (file (or (revision-file rev) (error "revision ~a has no file on disk" (revision-id rev))))
         (loader (namestring (merge-pathnames "load.lisp" *project-root*))))
    (multiple-value-bind (code out)
        (run-cmd "sbcl" (list "--noinform" "--non-interactive"
                              "--load" loader
                              "--load" (namestring file)
                              "--eval" (format nil "(sb-ext:exit :code (if (evo.kernel:verify-in-process ~s) 0 1))"
                                               (string goal-name))))
      (logf "~a" out)
      (logf ";; fresh process exit ~d => ~a" code (if (zerop code) "VERIFIED" "FAILED"))
      (zerop code))))

;;; ------------------------------------------------------------------
;;; Status line + seed world
;;; ------------------------------------------------------------------

(defun status-line ()
  (let ((*package* (find-package :world)) (*print-case* :upcase))
    (format nil "~a | revision ~d~@[ (~a)~]~a | generation ~d | budget ~d~%(:DATA ~s :DEFINITIONS ~s)~%Safety: ~s"
            (if (invariants) "IDLE" "UNSAFE")
            (if *current-revision* (revision-number *current-revision*) 0)
            (and *current-revision* (revision-id *current-revision*))
            (if (and *current-revision* (not (equal *generation* (revision-generation *current-revision*)))) "+drift" "")
            *generation* *budget*
            (let ((pl (table->plist world::*state*)))
              (loop for (k v) on pl by #'cddr collect (cons k v)))
            (mapcar #'cdr *definitions*)
            (loop for r in (property-report) collect (list :name (getf r :name) :status (getf r :status))))))

(defun freeze-base ()
  "Call once after seed + goals are loaded."
  (setf *base-snap* (snapshot)))

(defun seed-world ()
  "Generation 1: a counter and a safety property. The demo everything else must preserve."
  (setf world::*state* (plist->table '(:x 0)))
  (setf *definitions* '() *generation* 0)
  (evaluate '(defun world::counter () (gethash :x world::*state* 0)))
  (defproperty nonnegative-counter (>= (world::counter) 0))
  (incf *generation*))
