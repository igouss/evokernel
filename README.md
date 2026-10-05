# evokernel — an evolutionary Lisp kernel with an LLM at the REPL

A live SBCL image. The LLM is the hacker typing at its REPL. Every reply the model sends is read,
evaluated into the running heap, and either kept (every safety property still holds) or rolled back
(the heap is restored from a snapshot taken a moment earlier). When the goal's fixed cases and
generated cases all pass, the heap is frozen as a revision: in memory, as a plain `.lisp` file, and
as a git commit. A fresh SBCL process can load that file and re-run the checks. Rollback to any
revision is live — no restart.

Tokens are the fuel. This is the engine.

```lisp
(defun run (goal)
  (loop until (invariants)                       ; done when the heap says so
        for form = (ask-model (observe goal))    ; re-read, then one form
        do (assert (not (locked-p form)))        ; the kernel is not the world
           (let ((snap (snapshot)))
             (restart-case (eval form)           ; menu stays live until picked
               (abort () (restore snap))))))     ; bad commit, old heap, next turn
```

That is literally `evo.kernel:run` in `src/kernel.lisp`, with the plumbing left visible.

## Run it

Requires `sbcl`, `curl`, `git`. The `claude-code` backend also needs the `claude` CLI, logged in.
No Quicklisp, no ASDF, no Lisp HTTP libraries (HTTP goes through curl, JSON is 150 lines of in-tree
code).

```sh
./run.sh demo                        # offline. scripted "model". no API key. ~5 s.
EVO_BACKEND=anthropic ANTHROPIC_API_KEY=... ./run.sh          # real model, chat REPL
EVO_BACKEND=claude-code ./run.sh     # real model via `claude -p`, uses your Claude Code login
EVO_BACKEND=openai EVO_OPENAI_BASE_URL=http://localhost:11434/v1 EVO_MODEL=qwen2.5-coder ./run.sh   # ollama / llama.cpp / vllm
EVO_BACKEND=manual ./run.sh          # YOU are the model. kernel prints the prompt, you type the form.
./run.sh verify 2 reverse-string     # fresh process, load revision 2, run the goal checks, exit 0/1
```

The demo does the whole story from the thread, offline:

1. model tries `(defun reverse-string (s) (reverse s))` → **LOCKED** (goal forbids `reverse`), heap untouched
2. model writes a buggy version → **accepted** (no safety property broke), goal still fails, failure fed back
3. model does `(setf (gethash :x *state*) -1)` → **REJECTED**, `nonnegative-counter` invariant tripped, heap restored
4. model writes a correct version → 21 fixed + 1000 generated cases pass → **revision 2 committed** to git
5. a fresh SBCL loads `revisions/rev-0002.lisp` and re-verifies → exit 0
6. `(rollback 1)` → `reverse-string` is gone, `counter` survives; `(rollback 2)` → it's back. Same process throughout.

## The REPL

```
Live Lisp image REPL. Program loaded. /help for commands.
IDLE | revision 1 (revision-1800062965600964562-1) | generation 1 | budget 200000
(:DATA ((:X . 0)) :DEFINITIONS ((DEFUN COUNTER () (GETHASH :X *STATE* 0))))
Safety: ((:NAME :NONNEGATIVE-COUNTER :STATUS :PASS))
chat> /run reverse-string
```

| command | what |
|---|---|
| `/run GOAL` | the loop above, until GOAL + safety pass, then commit |
| `/eval FORM` | you evaluate a form, same lock/snapshot/invariant rules as the model |
| `/revisions` `/rollback N` `/verify N GOAL` | revision history, live rollback, fresh-process proof |
| `/state` `/defs` `/goals` `/budget N` | inspect / set |
| free text | chat with the model about the heap; nothing is evaluated |

Status line: `IDLE` means all safety properties pass; `UNSAFE` means the heap is currently in
violation (only possible via a rollback that failed to re-establish invariants, which is itself
rejected — so you should never see it). `+drift` after the revision id means the heap has moved
past the last committed revision.

## Layout

```
load.lisp                 loads everything, seeds the world, freezes base, commits revision 1
src/json.lisp             JSON in/out, no deps
src/kernel.lisp           WORLD package, lock check, snapshot/restore, goals, properties, run, revisions, git, rollback, fresh verify
src/model.lisp            adapters: anthropic | openai-compatible | claude-code | scripted | manual
src/repl.lisp             the chat> loop
goals/reverse-string.lisp the demo goal: 21 fixed cases, 1000 generated, reverse/nreverse forbidden
scripts/demo.lisp         the offline story
revisions/rev-NNNN.lisp   what the model grew. plain defuns. git-tracked. diff them.
```

## Design: image is truth at runtime, git is truth across time

The Smalltalk problem: once functions live in the image, the file is a lie. Answer here:

- `evo.kernel:*definitions*` is an ordered alist `(symbol . source-form)` maintained by `evaluate`
  for every definer form (`defun defmacro defvar defparameter defstruct defclass ...`) the model
  gets accepted. The image is still what runs; this list is what gets dumped.
- `commit-revision` writes `revisions/rev-NNNN.lisp`: `(in-package :world)`, the state as a plist,
  every definition pretty-printed, and one trailing bookkeeping call. Then `git add` + `git commit`
  of that one file. `git log -p revisions/` is the model's growth history, defun by defun.
- Loading a revision file in a fresh image evaluates the defuns normally, then
  `install-loaded-revision` re-reads the file to rebuild `*definitions*` — so the fresh image can
  observe, commit, and roll back exactly like the original.

Rollback does not reload from disk. It restores `*base-snap*` (the world as it was right after
seed + goals loaded), sets `*state*` from the revision, and re-evaluates the revision's definitions.
If invariants don't hold afterwards, the pre-rollback heap is restored and you get an error. The
heap is never left half-rolled.

## The fence (`locked-p`)

A form is refused before evaluation if it contains:

- any symbol from the kernel packages (`evo.*`, `sb-ext`, `sb-sys`, `sb-alien`, `sb-impl`, ...)
- `open with-open-file load compile-file delete-file eval compile defpackage in-package intern ...`
- a definer whose name is not a `WORLD` symbol — so `(defun reverse ...)` reads as `CL:REVERSE` and
  is refused; `(defun reverse-string ...)` interns in `WORLD` and is fine
- any symbol in the current goal's `:forbidden` list

Plus `*read-eval*` is nil. Evals, examples and property checks have no time limit by default: a
looping form hangs the run until you press Ctrl-C, which restores the pre-turn heap. Set
`evo.kernel:*eval-timeout*` to a number of seconds to put them back on a wall-clock leash.

**This is a blacklist, not a sandbox.** Be honest with yourself about that. The model can still:
allocate until the heap dies (`--dynamic-space-size` is your friend), spin a thread via a CL symbol
I forgot, or find a symbol I didn't think of. A timeout, if you set one, does not stop allocation.
If you point a hostile model at this, run it in a container with a memory limit, which you were
going to do anyway.

## What the model sees (`observe`)

Everything, every turn, fresh from the heap: the goal description, every fixed case with its
expected value, the state plist, the pretty-printed source of every grown definition, each safety
property with pass/fail, the goal status with the first 5 concrete failures (`(reverse-string "ab")
=> "bb", expected "ba"`), the last 6 rejected turns and why, and remaining budget. No chat history.
The heap is the memory. Context is re-derived, not accumulated — which is why this doesn't drift
the way a long agent conversation does.

## Goals and properties

```lisp
(evo.kernel:defgoal reverse-string
  :description "..."
  :forbidden '(reverse nreverse)
  :examples '(((reverse-string "ab") "ba") ...)          ; form + expected, EQUAL
  :generator #'evo-random-string                          ; () -> x
  :property (lambda (s) ...)                              ; x -> bool
  :trials 1000)

(evo.kernel:defproperty nonnegative-counter (>= (counter) 0))   ; must hold after EVERY accepted form
```

Goals live in `goals/*.lisp` and are loaded by `load.lisp`; a fresh verify process gets the same
goals, so "it passed in the original image" and "it passed in a cold image" are checked by the
same code. The model never sees the generator or the property, only the fixed cases and the
first failures from the generated ones.

## What this is not

- Not RL. "Bred through reward and punishment" is a nice line but the loop is rejection sampling
  with a 6-turn failure window. Nothing is learned across runs except what git holds. If you want
  evolution you want a population, crossover between revision files, and a fitness function that
  isn't binary. All of that is a few hundred lines on top of `commit-revision` and `rollback`.
- Not a proof. 1000 random strings is not `(forall s)`. Swap the generator for an enumerator or
  bolt on a property checker if you care.
- Not immune to unsourced functions, only intolerant of them. `(setf (symbol-function 'foo) (lambda ...))`
  lands in the heap and survives snapshot/restore, but it is not a definer form, so it never reaches
  `*definitions*`. That is exactly the image-vs-file drift this thing is supposed to kill, so
  `commit-revision` diffs live `WORLD` fbindings against `*definitions*` and **refuses to commit**
  a heap containing functions it cannot write down. The model can grow a closure; it cannot ship one.

## Budget

`*budget*` is tokens. The Anthropic adapter decrements by `input_tokens + output_tokens` from the
API response, the OpenAI adapter by `usage.total_tokens`, scripted/manual by 1. `budget-exhausted`
stops `run` cleanly. Insert more tokens with `/budget N`.
