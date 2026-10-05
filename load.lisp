;;;; load.lisp — load the kernel, the adapters, the REPL and every goal. No ASDF, no Quicklisp.
;;;;   sbcl --load load.lisp --eval '(evo.repl:main)'
(defvar cl-user::*evo-root* (directory-namestring *load-truename*))
(dolist (f '("src/json" "src/kernel" "src/model" "src/repl"))
  (load (merge-pathnames (concatenate 'string f ".lisp") cl-user::*evo-root*)))
(setf evo.kernel:*project-root* (truename cl-user::*evo-root*))
(evo.kernel:seed-world)
(dolist (g (directory (merge-pathnames "goals/*.lisp" cl-user::*evo-root*)))
  (load g))
(evo.kernel:freeze-base)
(setf sb-ext:*muffled-warnings* 'sb-kernel:redefinition-warning)
;; the revisions on disk are the history; the seed is committed once, so there is always something
;; to roll back to
(evo.kernel:load-revision-history)
(evo.kernel:ensure-seed)
