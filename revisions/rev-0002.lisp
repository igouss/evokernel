;;;; revision-2314432926320826449-3
;;;; generation 3  goal REVERSE-STRING  2026-10-05T05:25:45Z
;;;; Grown by the model, dumped by the kernel. Diff me.

(in-package :world)

;;; --- state ---
(setf *state* (evo.kernel::plist->table '(:x 0)))

;;; --- definitions ---

(defun counter () (gethash :x *state* 0))

(defun reverse-string (s)
  (let* ((n (length s)) (out (make-string n)))
    (dotimes (i n out) (setf (char out i) (char s (- n 1 i))))))

;;; --- kernel bookkeeping ---
(evo.kernel::install-loaded-revision "revision-2314432926320826449-3" 3 "REVERSE-STRING" '(counter
                                                                                           reverse-string))
