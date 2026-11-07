;;; test-ein-kernel-ops.el --- Live kernel operations -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-kernel-ops.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-kernel-ops.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-kernel-ops.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T033: list, open, kernelspec, execute, interrupt, REST restart and
;; shutdown against a private jupyter server.  T036: shutting down a
;; kernel this Emacs did not create asks first.

;;; Code:

(require 'ein-testing-live)
(require 'ein-notebook)
(require 'ein-notebooklist)

(ert-deftest ein:integration-kernel-ops ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          notebook)
      (ein:testing-empty-notebook "ops.ipynb")
      (unwind-protect
          ;; URL keeps its trailing slash: C20 regression check.
          (let* ((_ (setq notebook (ein:testing-login-and-open url token "ops.ipynb")))
                 (kernel (ein:$notebook-kernel notebook)))
            ;; List
            (should (buffer-live-p (ein:notebooklist-get-buffer
                                    (ein:$notebook-url-or-port notebook))))
            ;; Kernel selection
            (should (equal (ein:$kernelspec-name (ein:$notebook-kernelspec notebook))
                           "python3"))
            (should (ein:testing-wait-until (lambda () (ein:kernel-live-p kernel)) 30))
            ;; Execute
            (let ((r (ein:testing-execute kernel "1+1")))
              (should (equal (ein:testing-result-text r) "2")))
            ;; Interrupt
            (let (error-output)
              (ein:kernel-execute
               kernel "import time; time.sleep(30)"
               (list :output (cons (lambda (_ msg-type content _m)
                                     (when (equal msg-type "error")
                                       (setq error-output content)))
                                   nil))
               :silent nil)
              (should (ein:testing-wait-until
                       (lambda () (eq (ein:$kernel-status kernel) 'busy)) 10))
              (ein:kernel-interrupt kernel)
              (should (ein:testing-wait-until (lambda () error-output) 10))
              (should (equal (plist-get error-output :ename) "KeyboardInterrupt")))
            ;; Restart through REST keeps the kernel id
            (let ((id (ein:$kernel-kernel-id kernel)))
              (ein:kernel-restart-session kernel)
              (should (ein:testing-wait-until
                       (lambda () (and (eq (ein:$kernel-status kernel) 'idle)
                                       (ein:kernel-live-p kernel)))
                       30))
              (should (equal (ein:$kernel-kernel-id kernel) id))
              (should (equal (ein:testing-result-text
                              (ein:testing-execute kernel "x = 40; x + 2"))
                             "42")))
            ;; Shutdown
            (let ((id (ein:$kernel-kernel-id kernel))
                  done)
              (should (member id (ein:testing-kernel-ids url token)))
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (&rest _) (error "Unexpected confirmation"))))
                (ein:kernel-delete-session (lambda (_k) (setq done t)) :kernel kernel))
              (should (ein:testing-wait-until (lambda () done) 15))
              (should (ein:testing-wait-until
                       (lambda () (not (member id (ein:testing-kernel-ids url token))))
                       15))))
        (ein:testing-kill-notebook notebook)))))

(ert-deftest ein:integration-shutdown-foreign-kernel-asks ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let* ((ein:jupyter-server-use-subcommand "server")
           (kernel (cdr (ein:testing-rest url token "POST" "api/kernels"
                                          '(:name "python3"))))
           (kid (plist-get kernel :id))
           (logged nil)
           (asked 0))
      (should kid)
      (ein:testing-rest url token "POST" "api/sessions"
                        `(:path "foreign.ipynb" :type "notebook" :name ""
                          :kernel (:id ,kid)))
      (ein:notebooklist-login url (lambda (&rest _) (setq logged t)) nil nil token)
      (should (ein:testing-wait-until (lambda () logged) 20))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (cl-incf asked) nil)))
        (ein:kernel-delete-session nil :url-or-port (ein:url url) :path "foreign.ipynb"))
      (should (= asked 1))
      ;; Give a wrongly sent DELETE time to land before checking.
      (ein:testing-wait-until (lambda () nil) 2)
      (should (member kid (ein:testing-kernel-ids url token))))))

(provide 'test-ein-kernel-ops)
;;; test-ein-kernel-ops.el ends here
