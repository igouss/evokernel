;;;; json.lisp — minimal JSON encode/decode. No Quicklisp, no deps.
;;;; Objects decode to alists ((key . value) ...) with string keys,
;;;; arrays to simple-vectors, true/false/null to :true/:false/:null.

(defpackage :evo.json
  (:use :cl)
  (:export #:encode #:decode #:jref))

(in-package :evo.json)

;;; ---------- encode ----------

(defun write-json-string (s out)
  (write-char #\" out)
  (loop for c across s do
    (case c
      (#\" (write-string "\\\"" out))
      (#\\ (write-string "\\\\" out))
      (#\Newline (write-string "\\n" out))
      (#\Return (write-string "\\r" out))
      (#\Tab (write-string "\\t" out))
      (t (if (< (char-code c) 32)
             (format out "\\u~4,'0x" (char-code c))
             (write-char c out)))))
  (write-char #\" out))

(defun encode (x &optional (out nil))
  "Encode X as JSON. Alists with string/keyword/symbol keys -> objects,
   vectors/lists -> arrays, :true/:false/:null -> literals."
  (if (null out)
      (with-output-to-string (s) (encode x s))
      (typecase x
        ((eql :true)  (write-string "true" out))
        ((eql :false) (write-string "false" out))
        ((eql :null)  (write-string "null" out))
        ((eql t)      (write-string "true" out))
        (null         (write-string "[]" out))
        (string       (write-json-string x out))
        (integer      (format out "~d" x))
        (real         (format out "~f" x))
        (symbol       (write-json-string (string-downcase (symbol-name x)) out))
        (vector       (write-char #\[ out)
                      (loop for e across x for i from 0 do
                        (when (> i 0) (write-char #\, out))
                        (encode e out))
                      (write-char #\] out))
        (cons
         (if (and (consp (car x)) (or (stringp (caar x)) (symbolp (caar x))))
             ;; alist -> object
             (progn
               (write-char #\{ out)
               (loop for (k . v) in x for i from 0 do
                 (when (> i 0) (write-char #\, out))
                 (write-json-string (if (stringp k) k (string-downcase (symbol-name k))) out)
                 (write-char #\: out)
                 (encode v out))
               (write-char #\} out))
             (progn
               (write-char #\[ out)
               (loop for e in x for i from 0 do
                 (when (> i 0) (write-char #\, out))
                 (encode e out))
               (write-char #\] out))))
        (t (error "Cannot JSON-encode ~s" x)))))

;;; ---------- decode ----------

(defvar *in*)
(defvar *pos*)

(defun peek () (if (< *pos* (length *in*)) (char *in* *pos*) nil))
(defun next () (prog1 (peek) (incf *pos*)))
(defun skip-ws () (loop while (and (peek) (member (peek) '(#\Space #\Tab #\Newline #\Return))) do (next)))
(defun expect (c) (unless (eql (next) c) (error "JSON: expected ~s at ~d" c *pos*)))

(defun read-json-string ()
  (expect #\")
  (with-output-to-string (out)
    (loop
      (let ((c (next)))
        (cond ((null c) (error "JSON: unterminated string"))
              ((char= c #\") (return))
              ((char= c #\\)
               (let ((e (next)))
                 (case e
                   (#\n (write-char #\Newline out))
                   (#\t (write-char #\Tab out))
                   (#\r (write-char #\Return out))
                   (#\b (write-char #\Backspace out))
                   (#\f (write-char #\Page out))
                   (#\u (let ((code (parse-integer *in* :start *pos* :end (+ *pos* 4) :radix 16)))
                          (incf *pos* 4)
                          ;; surrogate pair
                          (when (and (<= #xD800 code #xDBFF)
                                     (string= (subseq *in* *pos* (min (length *in*) (+ *pos* 2))) "\\u"))
                            (let ((lo (parse-integer *in* :start (+ *pos* 2) :end (+ *pos* 6) :radix 16)))
                              (incf *pos* 6)
                              (setf code (+ #x10000 (ash (- code #xD800) 10) (- lo #xDC00)))))
                          (write-char (code-char code) out)))
                   (t (write-char e out)))))
              (t (write-char c out)))))))

(defun read-json-number ()
  (let ((start *pos*))
    (loop while (and (peek) (or (digit-char-p (peek)) (find (peek) "+-.eE"))) do (next))
    (let ((s (subseq *in* start *pos*)))
      (if (every (lambda (c) (or (digit-char-p c) (char= c #\-))) s)
          (parse-integer s)
          (let ((*read-default-float-format* 'double-float))
            (coerce (read-from-string s) 'double-float))))))

(defun read-json-value ()
  (skip-ws)
  (let ((c (peek)))
    (cond ((null c) (error "JSON: unexpected end"))
          ((char= c #\{)
           (next) (skip-ws)
           (if (eql (peek) #\}) (progn (next) '())
               (loop with acc = '()
                     do (skip-ws)
                        (let ((k (read-json-string)))
                          (skip-ws) (expect #\:)
                          (push (cons k (read-json-value)) acc))
                        (skip-ws)
                        (case (next)
                          (#\, nil)
                          (#\} (return (nreverse acc)))
                          (t (error "JSON: bad object at ~d" *pos*))))))
          ((char= c #\[)
           (next) (skip-ws)
           (if (eql (peek) #\]) (progn (next) (vector))
               (loop with acc = '()
                     do (push (read-json-value) acc)
                        (skip-ws)
                        (case (next)
                          (#\, nil)
                          (#\] (return (coerce (nreverse acc) 'simple-vector)))
                          (t (error "JSON: bad array at ~d" *pos*))))))
          ((char= c #\") (read-json-string))
          ((string= (subseq *in* *pos* (min (length *in*) (+ *pos* 4))) "true") (incf *pos* 4) :true)
          ((string= (subseq *in* *pos* (min (length *in*) (+ *pos* 5))) "false") (incf *pos* 5) :false)
          ((string= (subseq *in* *pos* (min (length *in*) (+ *pos* 4))) "null") (incf *pos* 4) :null)
          (t (read-json-number)))))

(defun decode (string)
  (let ((*in* string) (*pos* 0))
    (read-json-value)))

(defun jref (obj &rest path)
  "Walk a decoded JSON value: strings index objects, integers index arrays."
  (dolist (k path obj)
    (setf obj (etypecase k
                (string (cdr (assoc k obj :test #'string=)))
                (integer (if (and (vectorp obj) (< k (length obj))) (aref obj k) nil))))))
