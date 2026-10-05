;;;; revision-709446254952698294-3
;;;; generation 3  goal ROMAN  2026-10-05T06:02:38Z
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

(defun to-roman (n)
  (let ((pairs
         '((1000 . "M") (900 . "CM") (500 . "D") (400 . "CD") (100 . "C") (90 . "XC") (50 . "L")
           (40 . "XL") (10 . "X") (9 . "IX") (5 . "V") (4 . "IV") (1 . "I")))
        (out ""))
    (dolist (p pairs out)
      (loop while (>= n (car p))
            do (setf out (concatenate 'string out (cdr p))) (decf n (car p))))))

(defun from-roman (s)
  (flet ((val (c)
           (case (char-upcase c)
             (#\I 1)
             (#\V 5)
             (#\X 10)
             (#\L 50)
             (#\C 100)
             (#\D 500)
             (#\M 1000)
             (t 0))))
    (let ((total 0) (len (length s)))
      (dotimes (i len total)
        (let ((v (val (char s i)))
              (next
               (if (< (1+ i) len)
                   (val (char s (1+ i)))
                   0)))
          (if (< v next)
              (decf total v)
              (incf total v)))))))

;;; --- kernel bookkeeping ---
(evo.kernel::install-loaded-revision "revision-709446254952698294-3" 3 "ROMAN" '(counter life-step
                                                                                         to-roman
                                                                                         from-roman))
