;;; test-ein-log.el --- Tests for credential redaction -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-log.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-log.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-log.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T029 (SC-012): `ein:log--redact' masks credentials.

;;; Code:

(require 'ert)
(require 'ein-log)

(defun ein:testing-redacted-p (input secrets)
  (let ((out (ein:log--redact input)))
    (dolist (s secrets)
      (should-not (string-search s out)))
    out))

(ert-deftest ein:log-redact-token-query ()
  (let ((out (ein:testing-redacted-p "open http://h:8888/?token=abc123 now" '("abc123"))))
    (should (string-prefix-p "open http://h:8888/?token=" out))
    (should (string-suffix-p " now" out))))

(ert-deftest ein:log-redact-password ()
  (ein:testing-redacted-p "login password=secret&next=/" '("secret")))

(ert-deftest ein:log-redact-authorization ()
  (ein:testing-redacted-p "Authorization: token abc123" '("abc123")))

(ert-deftest ein:log-redact-cookies ()
  (ein:testing-redacted-p "Cookie: _xsrf=zz; username-h-8888=\"2|1:0|10:17|secretval\""
                          '("zz" "secretval"))
  (ein:testing-redacted-p "Set-Cookie: username-h-8888=\"2|abcdef\"; Path=/"
                          '("abcdef")))

(ert-deftest ein:log-redact-registered-secret ()
  (let ((ein:log--secrets nil))
    (ein:log--register-secret "f00dfeedcafe")
    (ein:testing-redacted-p "bare f00dfeedcafe in text" '("f00dfeedcafe"))))

(ert-deftest ein:log-redact-leaves-plain-text ()
  (let ((ein:log--secrets nil))
    (should (equal (ein:log--redact "Kernel busy... msg_id=abcd")
                   "Kernel busy... msg_id=abcd"))))

(ert-deftest ein:log-wrapper-redacts ()
  (let ((ein:log--secrets nil)
        (ein:log-level 40)
        (ein:log-message-level 0)
        (ein:log-all-buffer-name " *ein:test-log*"))
    (ein:log--register-secret "s3cr3tvalue")
    (unwind-protect
        (progn
          (ein:log 'info "url http://x/?token=%s" "s3cr3tvalue")
          (with-current-buffer ein:log-all-buffer-name
            (should-not (string-search "s3cr3tvalue" (buffer-string)))))
      (kill-buffer ein:log-all-buffer-name))))

(provide 'test-ein-log)
;;; test-ein-log.el ends here
