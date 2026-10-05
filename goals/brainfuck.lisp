;;;; goals/brainfuck.lisp — the model writes an interpreter, then the interpreter runs programs.
;;;; The hidden property feeds random input through an echo program and a reversing program.

(in-package :world)

(defun bf-random-input ()
  (coerce (loop repeat (random 20) collect (code-char (+ 32 (random 95)))) 'string))

(evo.kernel:defgoal brainfuck
  :description "Define (bf program input): run the Brainfuck PROGRAM (a string) on INPUT (a string)
and return its output as a string. The tape has at least 30000 cells, all 0, the pointer starts at
cell 0. Cells hold 0..255 and wrap (255 + 1 = 0, 0 - 1 = 255). > < + - . , [ ] as usual; ',' at end
of input stores 0. Any other character is a comment."
  :forbidden '(bf-random-input)
  :examples '(((bf "" "") "")
              ((bf "+++++++++[>++++++++<-]>." "") "H")
              ((bf ",." "a") "a")
              ((bf ",[.,]" "echo") "echo")
              ((bf "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++." "")
               "Hello World!
")
              ((char-code (char (bf "-." "") 0)) 255)
              ((bf "six times seven is 42: ++++++[>+++++++<-]>." "") "*")
              ((bf ">,[>,]<[.<]" "abc") "cba"))
  :generator #'bf-random-input
  :property (lambda (s)
              (and (string= (bf ",[.,]" s) s)
                   (string= (bf ">,[>,]<[.<]" s) (coerce (reverse (coerce s 'list)) 'string))))
  :trials 200)
