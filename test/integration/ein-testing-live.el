;;; ein-testing-live.el --- Helpers for live-server integration tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-testing-live.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-testing-live.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-testing-live.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Kernel execution and raw REST helpers shared by the US2 integration
;; tests.  Uses `ein:testing-wait-until' from test-ein-smoke.el.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)
(require 'ein-testing-server)
(require 'test-ein-smoke)
(require 'ein-kernel)

(defun ein:testing-empty-notebook (name)
  "Write an empty nbformat 4.5 notebook NAME in the server root."
  (with-temp-file (expand-file-name name ein:testing-server-dir)
    (insert "{\"cells\": [], \"metadata\": {\"kernelspec\": {\"name\": \"python3\", \"display_name\": \"Python 3\", \"language\": \"python\"}}, \"nbformat\": 4, \"nbformat_minor\": 5}"))
  name)

(defun ein:testing-execute (kernel code &optional timeout)
  "Execute CODE on KERNEL; return plist (:outputs :reply).
Outputs are (MSG-TYPE . CONTENT) in arrival order.  Waits up to
TIMEOUT seconds (default 20) for the reply and the idle status."
  (let ((outputs '()) reply msg-id)
    (setq msg-id
     (ein:kernel-execute
     kernel code
     (list :output (cons (lambda (_ msg-type content _metadata)
                           (push (cons msg-type content) outputs))
                         nil)
           :execute_reply (cons (lambda (_ content _metadata)
                                  (setq reply content))
                                nil))
     :silent nil))
    ;; Done when both execute_reply and status idle arrived (T051).
    (ein:testing-wait-until
     (lambda () (and reply (not (ein:kernel-get-callbacks-for-msg kernel msg-id))))
     (or timeout 20))
    (list :outputs (reverse outputs) :reply reply)))

(defun ein:testing-result-text (result)
  "The text/plain of the first execute_result in RESULT."
  (cl-loop for (type . content) in (plist-get result :outputs)
           when (equal type "execute_result")
           return (plist-get (plist-get content :data) :text/plain)))

(defun ein:testing-rest (url token method path &optional body)
  "Do METHOD URL/PATH with TOKEN and JSON BODY; return (STATUS . JSON)."
  (let ((url-request-method method)
        (url-request-extra-headers
         `(("Authorization" . ,(concat "token " token))
           ("Content-Type" . "application/json")))
        (url-request-data (and body (encode-coding-string (json-encode body) 'utf-8)))
        (url-show-status nil))
    (let ((buf (url-retrieve-synchronously (concat (file-name-as-directory url) path)
                                           t t 10)))
      (unwind-protect
          (with-current-buffer buf
            (goto-char (point-min))
            (re-search-forward "\n\r?\n" nil t)
            (cons url-http-response-status
                  (let ((json-object-type 'plist) (json-array-type 'list))
                    (ignore-errors (json-read)))))
        (kill-buffer buf)))))

(defun ein:testing-kernel-ids (url token)
  "Ids of the kernels running on URL."
  (mapcar (lambda (k) (plist-get k :id))
          (cdr (ein:testing-rest url token "GET" "api/kernels"))))

(defun ein:testing-log-text ()
  "Text of EIN's log buffer, or \"\"."
  (let ((buf (get-buffer ein:log-all-buffer-name)))
    (if buf (with-current-buffer buf (buffer-string)) "")))

(provide 'ein-testing-live)
;;; ein-testing-live.el ends here
