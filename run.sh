#!/usr/bin/env bash
# run.sh — start the chat REPL, or run the offline demo.
#   ./run.sh            chat REPL (needs EVO_BACKEND, see README)
#   ./run.sh demo       offline scripted demo, no model needed
#   ./run.sh verify N GOAL   fresh-process check of revision N
set -euo pipefail
cd "$(dirname "$0")"
case "${1:-chat}" in
  demo)   exec sbcl --noinform --non-interactive --load load.lisp --load scripts/demo.lisp ;;
  verify) exec sbcl --noinform --non-interactive --load load.lisp \
            --eval "(sb-ext:exit :code (if (evo.kernel:verify-fresh $2 \"$3\") 0 1))" ;;
  chat)   exec sbcl --noinform --load load.lisp --eval '(evo.repl:main)' --eval '(sb-ext:exit)' ;;
  *)      echo "usage: $0 [chat|demo|verify N GOAL]"; exit 2 ;;
esac
