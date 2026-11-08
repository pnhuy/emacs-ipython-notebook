;;; test-ein-server-auth.el --- Password login and base paths -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-server-auth.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-server-auth.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-server-auth.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T039 (FR-006): password login, a custom base_url and a wrong
;; password against a private jupyter server.

;;; Code:

(require 'ein-testing-live)
(require 'ein-notebook)
(require 'ein-notebooklist)

(defun ein:testing--text-in-logs-p (text)
  "Non-nil if TEXT occurs in an EIN log buffer or *Messages*."
  (cl-some (lambda (b)
             (and (string-match-p "\\`[ ]?\\*\\(?:ein\\|request\\|Messages\\)"
                                  (buffer-name b))
                  (with-current-buffer b
                    (save-excursion (goto-char (point-min))
                                    (search-forward text nil t)))))
           (buffer-list)))

(ert-deftest ein:integration-token-login-survives-stale-login-cookies ()
  "Login cookies of servers that are gone must not cause a 403.
Each jupyter server leaves a persistent username-HOST-PORT cookie
and cookies ignore the port.  With enough of them, curl's limit on
the Cookie header drops _xsrf and the server answers 403."
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          (host (url-host (url-generic-parse-url url)))
          (expiry (number-to-string (+ (truncate (float-time)) 86400)))
          logged failed)
      (with-temp-buffer
        (dotimes (i 30)
          (insert (mapconcat
                   #'identity
                   (list (concat "#HttpOnly_" host) "FALSE" "/" "FALSE" expiry
                         (format "username-%s-%d"
                                 (replace-regexp-in-string "[.:]" "-" host)
                                 (+ 1 i))
                         (concat "2|1:0|10:1700000000|" (make-string 320 ?a)))
                   "\t")
                  "\n"))
        (write-region (point-min) (point-max) (request--curl-cookie-jar) 'append))
      (clrhash ein:query-xsrf-cache)
      (ein:notebooklist-login url (lambda (&rest _) (setq logged t))
                              nil nil token)
      (cl-letf (((symbol-function 'ein:notebooklist-login--error-1)
                 (lambda (&rest _) (setq failed t))))
        (should (ein:testing-wait-until (lambda () (or logged failed)) 20)))
      (should-not failed)
      (should logged))))

(ert-deftest ein:integration-password-login ()
  :tags '(:integration)
  (ein:testing-with-server (url _token :password "ein-pw")
    (let ((ein:jupyter-server-use-subcommand "server")
          (ein:log-level (ein:log-level-name-to-int 'debug))
          (prompts 0)
          logged notebook)
      (ein:testing-empty-notebook "pw.ipynb")
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'read-passwd)
                       (lambda (&rest _) (cl-incf prompts) "ein-pw")))
              (ein:notebooklist-login url (lambda (&rest _) (setq logged t)))
              (should (ein:testing-wait-until (lambda () logged) 20)))
            (should (<= 1 prompts 2))
            (should (buffer-live-p (ein:notebooklist-get-buffer (ein:url url))))
            (ein:notebook-open (ein:url url) "pw.ipynb" nil
                               (lambda (nb &rest _) (setq notebook nb)) nil t)
            (should (ein:testing-wait-until (lambda () notebook) 30))
            (let ((kernel (ein:$notebook-kernel notebook)))
              (should (ein:testing-wait-until (lambda () (ein:kernel-live-p kernel)) 30))
              (should (equal (ein:testing-result-text (ein:testing-execute kernel "1+1"))
                             "2")))
            (should-not (ein:testing--text-in-logs-p "ein-pw")))
        (ein:testing-kill-notebook notebook)))))

(ert-deftest ein:integration-base-url ()
  :tags '(:integration)
  (ein:testing-with-server (url token :base-url "/ein-x/")
    (let ((ein:jupyter-server-use-subcommand "server")
          (urls '())
          saved notebook)
      (should (string-suffix-p "/ein-x/" url))
      (ein:testing-empty-notebook "base.ipynb")
      (advice-add 'ein:query-singleton-ajax :before
                  (lambda (u &rest _) (push u urls))
                  '((name . ein:testing-capture-url)))
      (unwind-protect
          (let* ((_ (setq notebook (ein:testing-login-and-open url token "base.ipynb")))
                 (kernel (ein:$notebook-kernel notebook)))
            (should (ein:testing-wait-until (lambda () (ein:kernel-live-p kernel)) 30))
            (should (equal (ein:testing-result-text (ein:testing-execute kernel "3*3"))
                           "9"))
            (ein:notebook-save-notebook notebook (lambda (&rest _) (setq saved t)))
            (should (ein:testing-wait-until (lambda () saved) 15))
            (should urls)
            (dolist (u urls)
              (should (string-prefix-p (directory-file-name url) u))
              (should (string-match-p "/ein-x/" u))))
        (advice-remove 'ein:query-singleton-ajax 'ein:testing-capture-url)
        (ein:testing-kill-notebook notebook)))))

(ert-deftest ein:integration-wrong-password ()
  :tags '(:integration)
  (ein:testing-with-server (url _token :password "ein-pw")
    (let ((ein:jupyter-server-use-subcommand "server")
          (start (float-time))
          (prompts 0)
          failed logged)
      (advice-add 'ein:notebooklist-login--error-1 :before
                  (lambda (&rest _) (setq failed t))
                  '((name . ein:testing-login-failed)))
      (unwind-protect
          (cl-letf (((symbol-function 'read-passwd)
                     (lambda (&rest _) (cl-incf prompts) "wrong")))
            (ein:notebooklist-login url (lambda (&rest _) (setq logged t)))
            (should (ein:testing-wait-until (lambda () failed) 15))
            ;; No retry loop: give stray retries a moment, then count.
            (ein:testing-wait-until (lambda () nil) 2)
            (should-not logged)
            (should (<= prompts 2))
            (should (< (- (float-time) start) 15)))
        (advice-remove 'ein:notebooklist-login--error-1 'ein:testing-login-failed)))))

(provide 'test-ein-server-auth)
;;; test-ein-server-auth.el ends here
