;;;; revision-4257517990501837456-2
;;;; generation 2  goal LIFE  2026-10-05T05:54:30Z
;;;; Grown by the model, dumped by the kernel. Diff me.

(in-package :world)

;;; --- state ---
(setf *state* (evo.kernel::plist->table '(:x 0)))

;;; --- definitions ---

(defun counter () (gethash :x *state* 0))

(defun life-step (cells)
  (let ((live (make-hash-table :test #'equal))
        (counts (make-hash-table :test #'equal))
        (result 'nil))
    (dolist (c cells) (setf (gethash c live) t))
    (dolist (c cells)
      (let ((x (first c)) (y (second c)))
        (loop for dx from -1 to 1
              do (loop for dy from -1 to 1
                       do (unless (and (= dx 0) (= dy 0))
                            (incf (gethash (list (+ x dx) (+ y dy)) counts 0)))))))
    (maphash (lambda (k n) (when (or (= n 3) (and (= n 2) (gethash k live))) (push k result)))
             counts)
    result))

;;; --- kernel bookkeeping ---
(evo.kernel::install-loaded-revision "revision-4257517990501837456-2" 2 "LIFE" '(counter life-step))
