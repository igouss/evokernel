;;;; goals/reverse-string.lisp — the demo goal from the thread.
;;;; 21 fixed cases + 1000 generated cases. REVERSE/NREVERSE are forbidden so the model
;;;; actually has to write the function instead of aliasing CL.

(in-package :world)

(defun evo-random-string ()
  (let* ((alphabet "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.,!?éàçüßλ中文")
         (n (random 41)))
    (coerce (loop repeat n collect (char alphabet (random (length alphabet)))) 'string)))

(evo.kernel:defgoal reverse-string
  :description "Define (reverse-string s): return a fresh string with the characters of S in
reverse order. Must work on the empty string, single chars, unicode, and strings with spaces.
Do not call REVERSE or NREVERSE."
  :forbidden '(reverse nreverse)
  :examples '(((reverse-string "") "")
              ((reverse-string "a") "a")
              ((reverse-string "ab") "ba")
              ((reverse-string "abc") "cba")
              ((reverse-string "hello") "olleh")
              ((reverse-string "hello world") "dlrow olleh")
              ((reverse-string "racecar") "racecar")
              ((reverse-string "12345") "54321")
              ((reverse-string "  ") "  ")
              ((reverse-string " a ") " a ")
              ((reverse-string "Lisp") "psiL")
              ((reverse-string "SBCL") "LCBS")
              ((reverse-string "a,b,c") "c,b,a")
              ((reverse-string "tab	sep") "pes	bat")
              ((reverse-string "éà") "àé")
              ((reverse-string "λx.x") "x.xλ")
              ((reverse-string "中文") "文中")
              ((reverse-string "AbCdEf") "fEdCbA")
              ((reverse-string "!?") "?!")
              ((reverse-string "the quick brown fox") "xof nworb kciuq eht")
              ((let ((s "immutable")) (reverse-string s) s) "immutable"))
  :generator #'evo-random-string
  :property (lambda (s)
              (let ((r (reverse-string s)))
                (and (stringp r)
                     (not (eq r s))
                     (= (length r) (length s))
                     (every (lambda (i) (char= (char r i) (char s (- (length s) 1 i))))
                            (loop for i below (length s) collect i))
                     (string= (reverse-string r) s))))
  :trials 1000)
