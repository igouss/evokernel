;;;; repl.lisp — chat> loop. Slash commands drive the kernel; anything else is sent to the model.

(defpackage :evo.repl
  (:use :cl :evo.kernel)
  (:export #:chat #:main))

(in-package :evo.repl)

(defparameter *help*
  "/help               this
/status             heap status line
/goals              registered goals
/run GOAL           let the model drive the heap until GOAL + safety pass, then commit
/revisions          accepted revisions (index, id, generation, git sha)
/rollback N|ID      replace the live heap with revision N — no restart
/verify N GOAL      spawn a fresh SBCL, load revision N, run GOAL's checks
/state              dump *state*
/defs               dump grown definitions (what gets written to git)
/eval FORM          evaluate FORM in WORLD yourself (same lock + snapshot rules as the model)
/budget N           set remaining token budget
/quit
anything else       chat with the model about the heap (nothing is evaluated)")

(defparameter *chat-system*
  "You are the assistant of a live Common Lisp image kernel. Answer questions about the world
you are shown (state, definitions, properties, goals). Be concise. Do not output code to execute;
the operator runs /run GOAL for that.")

(defun chat-observation ()
  (format nil "~a~%~%Goals: ~{~a~^, ~}~%Revisions: ~d"
          (status-line) (mapcar #'goal-name (list-goals)) (length *revisions*)))

(defun chat-with-model (text)
  (handler-case
      (multiple-value-bind (reply tokens)
          (funcall *model* *chat-system*
                   (list (cons "user" (format nil "World:~%~a~%~%Operator says: ~a" (chat-observation) text))))
        (decf *budget* (or tokens 1))
        (format t "~&~a~%" reply))
    (error (c) (format t "~&model error: ~a~%" c))))

(defun split (line)
  (let ((sp (position #\Space line)))
    (if sp (values (subseq line 0 sp) (string-trim " " (subseq line sp))) (values line ""))))

(defun operator-eval (text)
  (let* ((form (let ((*package* (find-package :world)) (*read-eval* nil)) (read-from-string text)))
         (why (locked-p form)))
    (if why
        (format t "~&LOCKED: ~a~%" why)
        (let ((snap (snapshot)))
          (handler-case
              (progn (format t "~&=> ~s~%" (evaluate form))
                     (multiple-value-bind (ok failures) (invariants)
                       (unless ok (error 'invariant-violation :failures failures)))
                     (incf *generation*))
            (error (c) (restore snap) (format t "~&REJECTED, heap restored: ~a~%" c)))))))

(defun print-revisions ()
  (if (null *revisions*)
      (format t "~&(none)~%")
      (loop for rev in (reverse *revisions*) for i from 1
            do (format t "~&#~d  ~a  generation ~d  goal ~a~@[  git ~a~]~%"
                       i (revision-id rev) (revision-generation rev)
                       (evo.kernel::revision-goal rev) (evo.kernel::revision-sha rev)))))

(defun handle (line)
  (multiple-value-bind (cmd arg) (split line)
    (cond
      ((string= cmd "/help") (format t "~&~a~%" *help*))
      ((string= cmd "/status") nil)
      ((string= cmd "/goals")
       (dolist (g (list-goals)) (format t "~&~a — ~a~%" (goal-name g) (goal-description g))))
      ((string= cmd "/run") (handler-case (run arg) (error (c) (format t "~&run failed: ~a~%" c))))
      ((string= cmd "/revisions") (print-revisions))
      ((string= cmd "/rollback")
       (handler-case (rollback (or (parse-integer arg :junk-allowed t) arg))
         (error (c) (format t "~&~a~%" c))))
      ((string= cmd "/verify")
       (multiple-value-bind (n goal) (split arg)
         (handler-case (verify-fresh (or (parse-integer n :junk-allowed t) n) goal)
           (error (c) (format t "~&~a~%" c)))))
      ((string= cmd "/state") (format t "~&~s~%" (evo.kernel::table->plist *state*)))
      ((string= cmd "/defs") (format t "~&~a~%" (evo.kernel::definitions-source)))
      ((string= cmd "/eval") (handler-case (operator-eval arg) (error (c) (format t "~&~a~%" c))))
      ((string= cmd "/budget") (setf *budget* (parse-integer arg)))
      ((string= cmd "/quit") (throw 'quit nil))
      ((and (plusp (length cmd)) (char= (char cmd 0) #\/)) (format t "~&unknown command; /help~%"))
      ((plusp (length (string-trim " " line))) (chat-with-model line))
      (t nil))))

(defun chat ()
  (format t "~&Live Lisp image REPL. Program loaded. /help for commands.~%")
  (catch 'quit
    (loop
      (format t "~&~a~%chat> " (status-line))
      (finish-output)
      (let ((line (read-line *standard-input* nil nil)))
        (when (null line) (return))
        (handler-case (handle (string-trim " " line))
          (sb-sys:interactive-interrupt () (format t "~&interrupted~%"))))))
  (format t "~&bye~%"))

(defun main ()
  (unless *model*
    (setf *model* (handler-case (evo.model:from-env)
                    (error (c) (format t "~&no model backend (~a); chat and /run disabled, everything else works~%" c)
                      (lambda (&rest r) (declare (ignore r)) (error "no model bound"))))))
  (chat))
