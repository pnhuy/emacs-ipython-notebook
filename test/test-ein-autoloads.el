;;; test-ein-autoloads.el --- Entry points when loaded from a clone -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-autoloads.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-autoloads.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-autoloads.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A clone loaded with `(use-package ein :load-path ".../lisp")' only
;; runs `(require 'ein)'.  The commands must still be reachable, and
;; `ein:login' must not depend on `ein-jupyter' being loaded already
;; (found by the T163 walkthrough: void `ein:jupyter-crib-running-servers').

;;; Code:

(require 'ert)

(defun ein:testing-autoloads--run (dir &rest forms)
  "Run FORMS in a fresh Emacs with DIR on `load-path'; return its output."
  (let ((root (expand-file-name ".." (file-name-directory
                                      (locate-library "test-ein-autoloads")))))
    (with-temp-buffer
      (apply #'call-process
             (expand-file-name invocation-name invocation-directory)
             nil t nil "-Q" "--batch"
             "--eval" (format "(setq package-user-dir %S)"
                              (or (getenv "EIN_DEPS_DIR")
                                  (expand-file-name ".deps/elpa" root)))
             "--eval" "(package-initialize)"
             "-L" dir
             (apply #'append (mapcar (lambda (f) (list "--eval" f)) forms)))
      (buffer-string))))

(ert-deftest ein:autoloads-entry-points-after-require-ein ()
  "After `make autoloads', `(require 'ein)' makes the commands callable."
  (let* ((root (expand-file-name ".." (file-name-directory
                                       (locate-library "test-ein-autoloads"))))
         (dir (make-temp-file "ein-autoloads-" t)))
    (unwind-protect
        (progn
          (dolist (f (directory-files (expand-file-name "lisp" root) t "\\.el\\'"))
            (unless (string-suffix-p "ein-autoloads.el" f)
              (copy-file f (file-name-as-directory dir))))
          ;; What `make autoloads' does, in the copy.
          (ein:testing-autoloads--run
           dir (format "(progn (require 'package) (package-generate-autoloads \"ein\" %S))"
                       (file-name-as-directory dir)))
          (should (file-exists-p (expand-file-name "ein-autoloads.el" dir)))
          (let ((out (ein:testing-autoloads--run
                      dir
                      "(require 'ein)"
                      "(princ (format \"CMDS=%S\" (mapcar #'commandp '(ein:run ein:login ein:stop ein:notebooklist-open))))"
                      "(princ (format \" CRIB=%S\" (fboundp 'ein:jupyter-crib-running-servers)))"
                      ;; The interactive spec of `ein:login' calls it.
                      "(princ (format \" SPEC=%S\" (condition-case err (progn (require 'ein-notebooklist) (cl-letf (((symbol-function 'ein:completing-read) (lambda (&rest _) \"8888\"))) (funcall-interactively (lambda () (interactive) (advice-eval-interactive-spec (cadr (interactive-form 'ein:notebooklist-login)))))) 'ok) (error (car err)))))")))
            (should (string-match-p "CMDS=(t t t t)" out))
            (should (string-match-p "CRIB=t" out))
            (should (string-match-p "SPEC=ok" out))))
      (delete-directory dir t))))

(ert-deftest ein:autoloads-require-ein-without-autoloads ()
  "Without a generated autoloads file, `(require 'ein)' still loads."
  (let* ((root (expand-file-name ".." (file-name-directory
                                       (locate-library "test-ein-autoloads"))))
         (dir (make-temp-file "ein-noautoloads-" t)))
    (unwind-protect
        (progn
          (dolist (f (directory-files (expand-file-name "lisp" root) t "\\.el\\'"))
            (unless (string-suffix-p "ein-autoloads.el" f)
              (copy-file f (file-name-as-directory dir))))
          (should (string-match-p
                   "EIN=t"
                   (ein:testing-autoloads--run
                    dir "(require 'ein)" "(princ (format \"EIN=%S\" (featurep 'ein)))"))))
      (delete-directory dir t))))

(provide 'test-ein-autoloads)
;;; test-ein-autoloads.el ends here
