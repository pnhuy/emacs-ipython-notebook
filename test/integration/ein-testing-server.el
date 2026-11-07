;;; ein-testing-server.el --- Start a private jupyter server for tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-testing-server.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-testing-server.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-testing-server.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `ein:testing-with-server' starts `jupyter server' on a free localhost
;; port with a random token (or a password), runs BODY, and always tears
;; the server and its temporary root directory down.  Tests using it are
;; skipped when jupyter is not installed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url)

(defvar ein:testing-server-timeout 30
  "Seconds to wait for the test server to answer.")

(defvar ein:testing-server-dir nil
  "Root directory of the current test server.")

(defvar ein:testing-server-last-buffer nil
  "Log buffer of the most recent test server (for assertions).")

(defun ein:testing-server--free-port ()
  "Return a free TCP port on localhost."
  (let* ((proc (make-network-process :name "ein-port-probe" :server t
                                     :host "127.0.0.1" :service t
                                     :family 'ipv4))
         (port (process-contact proc :service)))
    (delete-process proc)
    port))

(defun ein:testing-server--hash-password (password)
  "Return the jupyter_server hash of PASSWORD."
  (with-temp-buffer
    (unless (zerop (call-process
                    "python3" nil t nil "-I" "-c"
                    "from jupyter_server.auth import passwd; import sys; print(passwd(sys.argv[1]))"
                    password))
      (error "Cannot hash password: %s" (buffer-string)))
    (string-trim (buffer-string))))

(defun ein:testing-server--ready-p (url token)
  "Non-nil when GET URL/api answers 200."
  (let ((url-request-extra-headers
         (and token `(("Authorization" . ,(concat "token " token)))))
        (url-show-status nil))
    (condition-case nil
        (let ((buf (url-retrieve-synchronously (concat url "api") t t 1)))
          (when buf
            (prog1 (with-current-buffer buf
                     (and (boundp 'url-http-response-status)
                          (eql url-http-response-status 200)))
              (kill-buffer buf))))
      (error nil))))

(defun ein:testing-server--start (password base-url)
  "Start a server.  Return plist (:proc :buffer :dir :url :token)."
  (let* ((port (ein:testing-server--free-port))
         (token (and (not password)
                     (secure-hash 'sha256 (format "%s%s" (random) (float-time)))))
         (dir (make-temp-file "ein-it-" t))
         (buffer (generate-new-buffer " *ein-test-server*"))
         (args (append
                (list "server" "--no-browser"
                      (format "--port=%d" port)
                      "--ip=127.0.0.1"
                      (format "--ServerApp.root_dir=%s" dir))
                (if password
                    (list "--IdentityProvider.token="
                          (format "--PasswordIdentityProvider.hashed_password=%s"
                                  (ein:testing-server--hash-password password)))
                  (list (format "--IdentityProvider.token=%s" token)))
                (and base-url
                     (list (format "--ServerApp.base_url=%s" base-url)))))
         (proc (make-process :name "ein-test-server" :buffer buffer
                             :command (cons "jupyter" args)
                             :connection-type 'pipe :noquery t))
         (url (format "http://127.0.0.1:%d%s" port (or base-url "/"))))
    (setq ein:testing-server-last-buffer buffer)
    (let ((deadline (+ (float-time) ein:testing-server-timeout)))
      (while (and (process-live-p proc)
                  (not (ein:testing-server--ready-p url token)))
        (when (> (float-time) deadline)
          (delete-process proc)
          (error "Test server did not start: %s"
                 (with-current-buffer buffer (buffer-string))))
        (accept-process-output proc 0.2)))
    (unless (process-live-p proc)
      (error "Test server exited: %s" (with-current-buffer buffer (buffer-string))))
    (list :proc proc :buffer buffer :dir dir :url url :token token)))

(defun ein:testing-server--stop (server)
  "Tear SERVER down."
  (let ((proc (plist-get server :proc)))
    (when (process-live-p proc)
      (interrupt-process proc)
      (let ((deadline (+ (float-time) 5)))
        (while (and (process-live-p proc) (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (when (process-live-p proc) (delete-process proc))))
  (let ((dir (plist-get server :dir)))
    (when (and dir (file-directory-p dir))
      (delete-directory dir t))))

(cl-defmacro ein:testing-with-server ((url-var token-var &key password base-url)
                                      &rest body)
  "Run BODY with a private jupyter server.
URL-VAR is bound to its URL (ending in /), TOKEN-VAR to its token
\(nil with PASSWORD).  The server root directory is bound to
`ein:testing-server-dir'.  Skips when jupyter is not installed."
  (declare (indent 1))
  (let ((srv (make-symbol "server")))
    `(progn
       (unless (executable-find "jupyter")
         (ert-skip "jupyter not installed"))
       (let* ((,srv (ein:testing-server--start ,password ,base-url))
              (,url-var (plist-get ,srv :url))
              (,token-var (plist-get ,srv :token))
              (ein:testing-server-dir (plist-get ,srv :dir)))
         (ignore ,url-var ,token-var ein:testing-server-dir)
         (unwind-protect
             (progn ,@body)
           (ein:testing-server--stop ,srv)
           (when (buffer-live-p (plist-get ,srv :buffer))
             (kill-buffer (plist-get ,srv :buffer))))))))

(provide 'ein-testing-server)
;;; ein-testing-server.el ends here
