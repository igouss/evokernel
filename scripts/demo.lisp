;;;; scripts/demo.lisp — the whole story, offline, with a scripted "model". No API key needed.
;;;;
;;;; Turn 1: model tries to cheat with REVERSE          -> LOCKED, heap untouched
;;;; Turn 2: model writes a buggy reverse-string         -> accepted (no safety property broke), goal still fails
;;;; Turn 3: model breaks the safety property           -> REJECTED, heap restored
;;;; Turn 4: model writes a correct reverse-string      -> goal satisfied, revision 2 committed to git
;;;; Then: fresh SBCL verifies revision 2; rollback to revision 1 removes reverse-string but keeps
;;;; the counter demo; rollback to revision 2 brings it back. All without restarting this image.

(in-package :evo.kernel)

(setf *model*
      (evo.model:make-scripted
       '("```lisp
(defun reverse-string (s) (reverse s))
```"
         "```lisp
(defun reverse-string (s)
  (let ((out (make-string (length s))))
    (loop for i from 1 below (length s)
          do (setf (char out i) (char s (- (length s) 1 i))))
    out))
```"
         "```lisp
(setf (gethash :x *state*) -1)
```"
         "```lisp
(defun reverse-string (s)
  (let* ((n (length s)) (out (make-string n)))
    (dotimes (i n out)
      (setf (char out i) (char s (- n 1 i))))))
```")))

(defun say (fmt &rest args) (format t "~&~%;; ======== ~? ========~%" fmt args))

(format t "~&~a~%" (status-line))

(say "RUN goal reverse-string")
(let ((rev (run "reverse-string")))
  (assert rev () "demo: goal was not satisfied"))
(format t "~&~a~%" (status-line))
(format t "~&(reverse-string \"evokernel\") => ~s~%" (world::reverse-string "evokernel"))

(say "fresh-process verification of revision 2")
(assert (verify-fresh 2 "reverse-string") () "demo: fresh process failed")

(say "rollback to revision 1 (the seed) — reverse-string must vanish, counter must survive")
(rollback 1)
(format t "~&(fboundp 'reverse-string) => ~s   (counter) => ~s~%"
        (fboundp 'world::reverse-string) (world::counter))
(assert (not (fboundp 'world::reverse-string)))
(assert (eql 0 (world::counter)))

(say "roll forward to revision 2 — it's back")
(rollback 2)
(format t "~&(reverse-string \"evokernel\") => ~s~%" (world::reverse-string "evokernel"))
(assert (string= "lenrekove" (world::reverse-string "evokernel")))

(say "git log")
(multiple-value-bind (code out) (git "log" "--oneline") (declare (ignore code)) (format t "~a~%" out))

(say "DEMO OK — ~d tokens burned" *tokens-burned*)
