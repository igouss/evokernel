;;;; goals/roman.lisp — Roman numerals both ways. FORMAT is forbidden: (format nil "~@R" n)
;;;; would make it a one-liner. The hidden property checks the round trip AND compares with ~@R.

(in-package :world)

(defun roman-random-n () (1+ (random 3999)))

(evo.kernel:defgoal roman
  :description "Define (to-roman n) for 1 <= n <= 3999, returning an uppercase string in standard
subtractive notation (4 = IV, 9 = IX, 40 = XL, 90 = XC, 400 = CD, 900 = CM), and (from-roman s),
its inverse. Do not use FORMAT."
  :forbidden '(format formatter roman-random-n)
  :examples '(((to-roman 1) "I")
              ((to-roman 4) "IV")
              ((to-roman 9) "IX")
              ((to-roman 14) "XIV")
              ((to-roman 40) "XL")
              ((to-roman 90) "XC")
              ((to-roman 400) "CD")
              ((to-roman 1994) "MCMXCIV")
              ((to-roman 3999) "MMMCMXCIX")
              ((from-roman "I") 1)
              ((from-roman "MCMXCIV") 1994)
              ((from-roman "MMMCMXCIX") 3999))
  :generator #'roman-random-n
  :property (lambda (n)
              (and (string= (to-roman n) (format nil "~@R" n))
                   (= (from-roman (to-roman n)) n)))
  :trials 1000)
