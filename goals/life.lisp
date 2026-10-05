;;;; goals/life.lisp — Conway's Game of Life on an unbounded grid. Gliders must glide.
;;;; The hidden property compares random soups against a reference the model cannot see or touch.

(in-package :world)

(defun life-set= (a b)
  (and (= (length a) (length b))
       (= (length a) (length (remove-duplicates a :test #'equal)))
       (every (lambda (c) (member c b :test #'equal)) a)))

(defun life-ref (cells)
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (c cells)
      (loop for dx from -1 to 1
            do (loop for dy from -1 to 1
                     unless (and (zerop dx) (zerop dy))
                       do (incf (gethash (list (+ (first c) dx) (+ (second c) dy)) counts 0)))))
    (let ((next '()))
      (maphash (lambda (cell n)
                 (when (or (= n 3) (and (= n 2) (member cell cells :test #'equal)))
                   (push cell next)))
               counts)
      next)))

(defun life-random-soup ()
  (remove-duplicates (loop repeat (random 25) collect (list (random 8) (random 8))) :test #'equal))

(evo.kernel:defgoal life
  :description "Define (life-step cells): one generation of Conway's Game of Life on an unbounded
grid. CELLS is a list of live cells, each a list (x y) of integers, any order, no duplicates. Return
the live cells of the next generation in the same form, any order, no duplicates. Rules: a live cell
with 2 or 3 live neighbours survives; a dead cell with exactly 3 becomes alive; all else dies.
LIFE-SET= compares two cell lists ignoring order."
  :forbidden '(life-set= life-ref life-random-soup)
  :examples '(((life-step '()) ())
              ((life-step '((0 0))) ())
              ((life-set= (life-step '((0 0) (0 1) (1 0) (1 1))) '((0 0) (0 1) (1 0) (1 1))) t)
              ((life-set= (life-step '((0 1) (1 1) (2 1))) '((1 0) (1 1) (1 2))) t)
              ((life-set= (life-step (life-step '((0 1) (1 1) (2 1)))) '((0 1) (1 1) (2 1))) t)
              ((life-set= (life-step (life-step (life-step (life-step '((1 0) (2 1) (0 2) (1 2) (2 2))))))
                          '((2 1) (3 2) (1 3) (2 3) (3 3)))
               t)
              ((life-set= (life-step '((-5 -5) (-4 -5) (-3 -5))) '((-4 -6) (-4 -5) (-4 -4))) t))
  :generator #'life-random-soup
  :property (lambda (cells) (life-set= (life-step cells) (life-ref cells)))
  :trials 300)
