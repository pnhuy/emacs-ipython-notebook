;;; ein-test-init.el --- Cask-free batch test harness for EIN -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-test-init.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-test-init.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-test-init.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Run from the repository root:
;;
;;   emacs -Q --batch -l test/ein-test-init.el
;;
;; Environment:
;;   EIN_DEPS_DIR       package dir (default <repo>/.deps/elpa)
;;   EIN_TEST_SELECTOR  ERT selector, read with `read'
;;                      (default (not (tag :integration)))
;;   EIN_TEST_FILES     optional space-separated list of test files to
;;                      load instead of all of them
;;
;; Independent of the user's personal configuration.

;;; Code:

(require 'package)
(require 'ert)

(defconst ein:test-init--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root.")

(setq package-user-dir
      (let ((env (getenv "EIN_DEPS_DIR")))
        (if (and env (not (string-empty-p env)))
            (expand-file-name env)
          (expand-file-name ".deps/elpa" ein:test-init--root))))
(package-initialize)

(setq default-directory ein:test-init--root)
(push (expand-file-name "lisp" ein:test-init--root) load-path)
(push (expand-file-name "test" ein:test-init--root) load-path)
(push (expand-file-name "test/integration" ein:test-init--root) load-path)
(push (expand-file-name "test/nbview" ein:test-init--root) load-path)
(setq load-prefer-newer t)

(load (expand-file-name "test/testein.el" ein:test-init--root) nil t)

(defun ein:test-init--files ()
  "Return the test files to load."
  (let ((env (getenv "EIN_TEST_FILES")))
    (if (and env (not (string-empty-p env)))
        (mapcar (lambda (f) (expand-file-name f ein:test-init--root))
                (split-string env))
      (append
       (directory-files (expand-file-name "test" ein:test-init--root)
                        t "\\`test-ein.*\\.el\\'")
       (let ((d (expand-file-name "test/nbview" ein:test-init--root)))
         (and (file-directory-p d) (directory-files d t "\\`test-.*\\.el\\'")))
       (let ((d (expand-file-name "test/integration" ein:test-init--root)))
         (and (file-directory-p d) (directory-files d t "\\`test-.*\\.el\\'")))))))

(dolist (file (ein:test-init--files))
  (load file nil t))

(ert-run-tests-batch-and-exit
 (let ((env (getenv "EIN_TEST_SELECTOR")))
   (if (and env (not (string-empty-p env)))
       (car (read-from-string env))
     '(not (tag :integration)))))

(provide 'ein-test-init)
;;; ein-test-init.el ends here
