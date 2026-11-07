;;; test-ein-smoke.el --- Live open/execute/save smoke test -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-smoke.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-smoke.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-smoke.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; SC-001, SC-012, G1: against a private jupyter server, open the smoke
;; notebook (no code runs on open), execute it, save it, and validate
;; the saved file with nbformat.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-testing-server)
(require 'ein-testing-nbformat)
(require 'ein-notebook)
(require 'ein-notebooklist)

(defun ein:testing-wait-until (pred seconds)
  "Spin the event loop until PRED is non-nil or SECONDS pass.
Return PRED's final value."
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (funcall pred)))

(defun ein:testing-kill-notebook (notebook)
  "Kill NOTEBOOK's buffer and kernel without prompting."
  (when notebook
    (let ((buffer (ein:notebook-buffer notebook)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (let ((kill-buffer-query-functions nil)
              (ein:notebook-kill-buffer-ask nil))
          (ignore-errors (kill-buffer buffer)))))))

(defun ein:testing-login-and-open (url token path)
  "Log in to URL with TOKEN and open notebook PATH; return the notebook."
  (let (logged notebook)
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _) (error "Unexpected password prompt"))))
      (ein:notebooklist-login url (lambda (&rest _) (setq logged t)) nil nil token))
    (should (ein:testing-wait-until (lambda () logged) 20))
    (ein:notebook-open url path nil (lambda (nb &rest _) (setq notebook nb)) nil t)
    (should (ein:testing-wait-until (lambda () notebook) 30))
    notebook))

(ert-deftest ein:integration-smoke-open-execute-save ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          (file (expand-file-name "smoke.ipynb" ein:testing-server-dir))
          (executed '())
          notebook)
      (copy-file (ein:testing-fixture "smoke.ipynb") file)
      (unwind-protect
          (let ((orig (symbol-function 'ein:kernel-execute)))
            (cl-letf (((symbol-function 'ein:kernel-execute)
                       (lambda (&rest args)
                         (push (nth 1 args) executed)
                         (apply orig args))))
              ;; No trailing slash: a trailing "/" currently yields
              ;; "ws://host//api/..." (404); fixed and covered in US2 (T039).
              (setq notebook (ein:testing-login-and-open
                              (directory-file-name url) token "smoke.ipynb"))
              (should (ein:testing-wait-until
                       (lambda () (ein:kernel-live-p (ein:$notebook-kernel notebook)))
                       30))
              ;; G1: opening executed nothing.
              (should (null executed))
              (with-current-buffer (ein:notebook-buffer notebook)
                (let ((code-cells (cl-remove-if-not
                                   (lambda (c) (ein:codecell-p c))
                                   (ein:worksheet-get-cells ein:%worksheet%))))
                  (mapc #'ein:cell-execute code-cells)
                  (should (ein:testing-wait-until
                           (lambda ()
                             (cl-notany (lambda (c) (oref c running)) code-cells))
                           60))
                  (should (= (length executed) (length code-cells)))))
              (let (saved)
                (ein:notebook-save-notebook notebook (lambda (&rest _) (setq saved t)))
                (should (ein:testing-wait-until (lambda () saved) 20)))))
        (ein:testing-kill-notebook notebook))
      (ein:testing-nbformat-validate file)
      (let* ((orig (json-parse-string
                    (with-temp-buffer
                      (insert-file-contents (ein:testing-fixture "smoke.ipynb"))
                      (buffer-string))
                    :object-type 'alist :array-type 'list))
             (saved (json-parse-string
                     (with-temp-buffer (insert-file-contents file) (buffer-string))
                     :object-type 'alist :array-type 'list))
             (ids (lambda (nb) (mapcar (lambda (c) (alist-get 'id c))
                                       (alist-get 'cells nb)))))
        (should (equal (funcall ids saved) (funcall ids orig)))
        (should (equal (alist-get 'tags (alist-get 'metadata (nth 1 (alist-get 'cells saved))))
                       '("keep-tag")))))))

(provide 'test-ein-smoke)
;;; test-ein-smoke.el ends here
