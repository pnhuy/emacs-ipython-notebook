;;; ein-log.el --- Logging module for ein.el    -*- lexical-binding:t -*-

;; Copyright (C) 2012- Takafumi Arakaki

;; Author: Takafumi Arakaki <aka.tkf at gmail.com>

;; This file is NOT part of GNU Emacs.

;; ein-log.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-log.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-log.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'ein-core)

(defvar ein:log-all-buffer-name "*ein:log-all*")

(defvar ein:log-level-def
  '(;; debugging
    (blather . 60) (trace . 50) (debug . 40)
    ;; information
    (verbose . 30) (info . 20)
    ;; errors
    (warn . 10) (error . 0))
  "Named logging levels.")
;; Some names are stolen from supervisord (http://supervisord.org/logging.html)

(defvar ein:log-level 30)
(defvar ein:log-message-level 20)

(defvar ein:log-print-length 10 "`print-length' for `ein:log'")
(defvar ein:log-print-level 1 "`print-level' for `ein:log'")
(defvar ein:log-max-string 1000)

(defun ein:log-set-level (level)
  (setq ein:log-level (ein:log-level-name-to-int level)))

(defun ein:log-set-message-level (level)
  (setq ein:log-message-level (ein:log-level-name-to-int level)))

(defun ein:log-level-int-to-name (int)
  (cl-loop for (n . i) in ein:log-level-def
        when (>= int i)
        return n
        finally 'error))

(defun ein:log-level-name-to-int (name)
  (cdr (assq name ein:log-level-def)))

(defsubst ein:log-strip-timestamp (msg)
  (replace-regexp-in-string "^[0-9: ]+" "" msg))

;;; Credential redaction (SC-012)

(defvar ein:log--secrets nil
  "Literal secret strings (tokens, passwords) that must never be logged.
Add to it with `ein:log--register-secret'.")

(defconst ein:log--redacted "<redacted>"
  "Replacement text for redacted credentials.")

(defconst ein:log--redact-patterns
  '(;; token=..., password=..., _xsrf=... in URLs and form bodies.
    ("\\(?:^\\|[^[:alnum:]_-]\\)\\(?:token\\|password\\|_xsrf\\)=\\([^&[:space:]\"';]+\\)" . 1)
    ;; Authorization: token X / Bearer X / Basic X
    ("[Aa]uthorization:?[[:space:]]+\\(?:[Tt]oken\\|[Bb]earer\\|[Bb]asic\\)?[[:space:]]*\\([^[:space:]\"',]+\\)" . 1)
    ;; Cookie / Set-Cookie header values: every NAME=VALUE pair.
    ("\\(?:[Ss]et-\\)?[Cc]ookie:?[[:space:]]+[^=[:space:]]+=\\(\"[^\"]*\"\\|[^;[:space:]]*\\)" . 1)
    (";[[:space:]]*[^=;[:space:]]+=\\(\"[^\"]*\"\\|[^;[:space:]]*\\)" . 1))
  "Alist of (REGEXP . SUBEXP); the SUBEXP match is replaced by a mask.
The cookie continuation pattern only fires on text that also matched
a cookie header, see `ein:log--redact'.")

(defun ein:log--register-secret (secret)
  "Remember SECRET so that `ein:log--redact' masks it everywhere."
  (when (and (stringp secret) (>= (length secret) 4))
    (cl-pushnew secret ein:log--secrets :test #'equal))
  secret)

(defun ein:log--redact-1 (string regexp subexp)
  (replace-regexp-in-string regexp ein:log--redacted string t t subexp))

(defun ein:log--redact (string)
  "Return STRING with tokens, passwords, cookies and registered secrets masked."
  (if (not (stringp string))
      string
    (let ((case-fold-search nil)
          (out string))
      (dolist (secret ein:log--secrets)
        (setq out (string-replace secret ein:log--redacted out)))
      (pcase-dolist (`(,re . ,sub) (butlast ein:log--redact-patterns))
        (setq out (ein:log--redact-1 out re sub)))
      ;; Remaining cookie pairs, only on lines that carry a cookie header.
      (when (string-match-p "[Cc]ookie:" out)
        (pcase-let ((`(,re . ,sub) (car (last ein:log--redact-patterns))))
          (setq out
                (mapconcat
                 (lambda (line)
                   (if (string-match-p "[Cc]ookie:" line)
                       (ein:log--redact-1 line re sub)
                     line))
                 (split-string out "\n") "\n"))))
      out)))

(defun ein:log-wrapper (level func)
  (setq level (ein:log-level-name-to-int level))
  (when (<= level ein:log-level)
    (let* ((levname (ein:log-level-int-to-name level))
           (print-level ein:log-print-level)
           (print-length ein:log-print-length)
           (msg (format "%s: [%s] %s" (format-time-string "%H:%M:%S:%3N") levname
                        (ein:log--redact (funcall func))))
           (orig-buffer (current-buffer)))
      (if (and ein:log-max-string
               (> (length msg) ein:log-max-string))
          (setq msg (substring msg 0 ein:log-max-string)))
      (ein:with-read-only-buffer (get-buffer-create ein:log-all-buffer-name)
        (goto-char (point-max))
        (insert msg (format " @%S" orig-buffer) "\n"))
      (when (<= level ein:log-message-level)
        (message "ein: %s" (ein:log-strip-timestamp msg))))))

(make-obsolete-variable 'ein:debug nil "0.17.0")

(defmacro ein:log (level string &rest args)
  (declare (indent 1))
  `(ein:log-wrapper ,level (lambda () (format ,string ,@args))))

(defsubst ein:debug-p ()
  "Set to non-`nil' to raise errors instead of suppressing it.
Change the behavior of `ein:log-ignore-errors'."
  (>= ein:log-level (alist-get 'debug ein:log-level-def)))

(defun ein:log-pop-to-ws-buffer ()
  (interactive)
  (-if-let* ((kernel (ein:get-kernel--notebook))
             (websocket (ein:$kernel-websocket kernel)))
      (pop-to-buffer
       (websocket-get-debug-buffer-create
        (ein:$websocket-ws websocket)))
    (message "Must be run from notebook buffer")))

(defun ein:log-pop-to-request-buffer ()
  (interactive)
  (aif (get-buffer request-log-buffer-name)
      (pop-to-buffer it)
    (message "No buffer %s" request-log-buffer-name)))

(defun ein:log-pop-to-all-buffer ()
  (interactive)
  (pop-to-buffer (get-buffer-create ein:log-all-buffer-name)))

(provide 'ein-log)

;;; ein-log.el ends here
