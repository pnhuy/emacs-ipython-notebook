;;; test-ein-no-secrets.el --- Credentials stay out of logs -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-no-secrets.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-no-secrets.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-no-secrets.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T035 (SC-012): with EIN debug logging on, a full login, open,
;; execute and save cycle leaves the token out of every EIN log
;; buffer, the request.el log and *Messages*.

;;; Code:

(require 'ein-testing-live)
(require 'ein-notebook)
(require 'ein-notebooklist)

(defun ein:testing--log-buffers ()
  "Buffers EIN or request.el may write diagnostics to."
  (cl-remove-if-not
   (lambda (b)
     (let ((name (buffer-name b)))
       (or (string-match-p "\\`[ ]?\\*\\(?:ein\\|request\\)" name)
           (equal name "*Messages*")
           (equal name "*Warnings*"))))
   (buffer-list)))

(ert-deftest ein:integration-no-secrets-in-logs ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          (ein:log-level (ein:log-level-name-to-int 'debug))
          (ein:log-message-level (ein:log-level-name-to-int 'debug))
          ;; request.el's own debug levels dump raw HTTP bodies and are
          ;; outside EIN's redaction (documented in compatibility.md);
          ;; keep them at their defaults.
          notebook)
      (ein:testing-empty-notebook "secret.ipynb")
      (unwind-protect
          (let* ((_ (setq notebook (ein:testing-login-and-open url token "secret.ipynb")))
                 (kernel (ein:$notebook-kernel notebook)))
            (should (ein:testing-wait-until (lambda () (ein:kernel-live-p kernel)) 30))
            (should (equal (ein:testing-result-text (ein:testing-execute kernel "6*7"))
                           "42"))
            (ein:notebook-save-notebook notebook)
            (ein:testing-wait-until (lambda () nil) 1)
            (should (> (length (ein:testing-log-text)) 0))
            (dolist (buf (ein:testing--log-buffers))
              (with-current-buffer buf
                ;; Report the offending buffer's name on failure.
                (should-not (and (save-excursion
                                   (goto-char (point-min))
                                   (search-forward token nil t))
                                 (buffer-name))))))
        (ein:testing-kill-notebook notebook)))))

(provide 'test-ein-no-secrets)
;;; test-ein-no-secrets.el ends here
