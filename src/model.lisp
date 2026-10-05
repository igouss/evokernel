;;;; model.lisp — the fuel pump. Adapters return (values text tokens-used).
;;;; HTTP goes through curl via run-program: zero Lisp HTTP/TLS deps.

(defpackage :evo.model
  (:use :cl)
  (:export #:make-anthropic #:make-openai #:make-scripted #:make-manual #:from-env))

(in-package :evo.model)

(defun getenv (name &optional default)
  (let ((v (sb-ext:posix-getenv name)))
    (if (and v (plusp (length v))) v default)))

(defun curl-json (url headers body)
  "POST BODY (a string) to URL. Returns decoded JSON. Signals on transport failure."
  (let* ((out (make-string-output-stream))
         (args (append (list "-sS" "--max-time" "180" "-X" "POST" url
                             "-H" "content-type: application/json")
                       (loop for h in headers append (list "-H" h))
                       (list "--data-binary" "@-")))
         (p (sb-ext:run-program "curl" args :search t :output out :error out
                                            :input (make-string-input-stream body))))
    (unless (zerop (sb-ext:process-exit-code p))
      (error "curl failed: ~a" (get-output-stream-string out)))
    (let ((text (get-output-stream-string out)))
      (handler-case (evo.json:decode text)
        (error () (error "non-JSON reply: ~a" (subseq text 0 (min 300 (length text)))))))))

;;; ---------- Anthropic Messages API ----------

(defun make-anthropic (&key (model (getenv "EVO_MODEL" "claude-sonnet-5-5"))
                            (api-key (getenv "ANTHROPIC_API_KEY"))
                            (max-tokens 2048))
  (unless api-key (error "ANTHROPIC_API_KEY not set"))
  (lambda (system messages)
    (let* ((body (evo.json:encode
                  `(("model" . ,model)
                    ("max_tokens" . ,max-tokens)
                    ("system" . ,system)
                    ("messages" . ,(coerce (loop for (role . content) in messages
                                                  collect `(("role" . ,role) ("content" . ,content)))
                                           'vector)))))
           (reply (curl-json "https://api.anthropic.com/v1/messages"
                             (list (format nil "x-api-key: ~a" api-key)
                                   "anthropic-version: 2023-06-01")
                             body)))
      (when (evo.json:jref reply "error")
        (error "anthropic: ~a" (evo.json:jref reply "error" "message")))
      (values (apply #'concatenate 'string
                     (loop for block across (or (evo.json:jref reply "content") #())
                           when (equal (evo.json:jref block "type") "text")
                             collect (evo.json:jref block "text")))
              (+ (or (evo.json:jref reply "usage" "input_tokens") 0)
                 (or (evo.json:jref reply "usage" "output_tokens") 0))))))

;;; ---------- OpenAI-compatible (ollama, llama.cpp, vllm, ...) ----------

(defun make-openai (&key (model (getenv "EVO_MODEL" "llama3.1"))
                         (base-url (getenv "EVO_OPENAI_BASE_URL" "http://localhost:11434/v1"))
                         (api-key (getenv "OPENAI_API_KEY" "none"))
                         (max-tokens 2048))
  (lambda (system messages)
    (let* ((body (evo.json:encode
                  `(("model" . ,model)
                    ("max_tokens" . ,max-tokens)
                    ("messages" . ,(coerce (cons `(("role" . "system") ("content" . ,system))
                                                 (loop for (role . content) in messages
                                                       collect `(("role" . ,role) ("content" . ,content))))
                                           'vector)))))
           (reply (curl-json (format nil "~a/chat/completions" (string-right-trim "/" base-url))
                             (list (format nil "authorization: Bearer ~a" api-key))
                             body)))
      (when (evo.json:jref reply "error")
        (error "openai: ~a" (evo.json:jref reply "error" "message")))
      (values (evo.json:jref reply "choices" 0 "message" "content")
              (or (evo.json:jref reply "usage" "total_tokens") 1)))))

;;; ---------- Scripted: a canned sequence of replies. Offline demo + tests. ----------

(defun make-scripted (replies)
  "REPLIES: list of strings. Each call pops one. Burns 1 token per call."
  (let ((queue (copy-list replies)))
    (lambda (system messages)
      (declare (ignore system messages))
      (if queue
          (values (pop queue) 1)
          (error "scripted model ran out of lines")))))

;;; ---------- Manual: you are the model. Prompt in, form out. ----------

(defun make-manual (&key (stream *query-io*))
  (lambda (system messages)
    (declare (ignore system))
    (format stream "~&---- MODEL PROMPT ----~%~a~%---- your form (one line, or ```lisp block ending with ```) ----~%"
            (cdr (first (last messages))))
    (finish-output stream)
    (let ((line (read-line stream)))
      (values (if (search "```" line)
                  (with-output-to-string (s)
                    (write-line line s)
                    (loop for l = (read-line stream nil "```")
                          do (write-line l s)
                          until (search "```" l)))
                  line)
              1))))

(defun from-env ()
  "Pick an adapter from EVO_BACKEND: anthropic | openai | manual."
  (let ((backend (string-downcase (getenv "EVO_BACKEND" "anthropic"))))
    (cond ((string= backend "anthropic") (make-anthropic))
          ((string= backend "openai") (make-openai))
          ((string= backend "manual") (make-manual))
          (t (error "unknown EVO_BACKEND ~a" backend)))))
