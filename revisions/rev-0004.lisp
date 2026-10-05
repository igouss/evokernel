;;;; revision-2427675705131979978-2
;;;; generation 2  goal BRAINFUCK  2026-10-05T06:12:16Z
;;;; Grown by the model, dumped by the kernel. Diff me.

(in-package :world)

;;; --- state ---
(setf *state* (evo.kernel::plist->table '(:x 0)))

;;; --- definitions ---

(defun counter () (gethash :x *state* 0))

(defun bf (program input)
  (let* ((n (length program))
         (jump (make-array n :initial-element 0))
         (stack 'nil)
         (tape (make-array 30000 :element-type '(unsigned-byte 8) :initial-element 0))
         (ptr 0)
         (ip 0)
         (in 0)
         (inlen (length input))
         (out (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (dotimes (i n)
      (case (char program i)
        (#\[ (push i stack))
        (#\]
         (when stack
           (let ((j (pop stack)))
             (setf (aref jump i) j
                   (aref jump j) i))))))
    (loop while (< ip n)
          do (case (char program ip)
               (#\> (setf ptr (mod (1+ ptr) 30000)))
               (#\< (setf ptr (mod (1- ptr) 30000)))
               (#\+ (setf (aref tape ptr) (mod (1+ (aref tape ptr)) 256)))
               (#\- (setf (aref tape ptr) (mod (1- (aref tape ptr)) 256)))
               (#\. (vector-push-extend (code-char (aref tape ptr)) out))
               (#\,
                (setf (aref tape ptr)
                        (if (< in inlen)
                            (prog1 (mod (char-code (char input in)) 256) (incf in))
                            0)))
               (#\[ (when (zerop (aref tape ptr)) (setf ip (aref jump ip))))
               (#\] (unless (zerop (aref tape ptr)) (setf ip (aref jump ip))))) (incf ip))
    (coerce out 'simple-string)))

;;; --- kernel bookkeeping ---
(evo.kernel::install-loaded-revision "revision-2427675705131979978-2" 2 "BRAINFUCK" '(counter bf))
