;;; install-deps.el --- Install EIN dev dependencies into .deps -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; install-deps.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; install-deps.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with install-deps.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with: emacs -Q --batch -l tools/install-deps.el
;;
;; Installs the packages listed in the Package-Requires header of
;; lisp/ein.el, plus test-only packages, into <repo>/.deps/elpa.  It
;; never touches the user's ~/.emacs.d.  Exits non-zero on failure.

;;; Code:

(require 'package)
(require 'lisp-mnt)
(require 'cl-lib)

(defconst ein:deps--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Repository root.")

(defconst ein:deps--test-only '(mocker f s package-lint)
  "Packages needed only for tests and linting.")

(defun ein:deps--package-requires ()
  "Return the dependency names from lisp/ein.el's Package-Requires."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/ein.el" ein:deps--root))
    (let ((reqs (package-read-from-string
                  (mapconcat #'identity (lm-header-multiline "package-requires") " "))))
      (delq 'emacs (mapcar #'car reqs)))))

(defun ein:deps-install ()
  "Install all dependencies; exit non-zero on failure."
  (setq package-user-dir (expand-file-name ".deps/elpa" ein:deps--root)
        package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                           ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                           ("melpa" . "https://melpa.org/packages/")))
  (package-initialize)
  (let ((wanted (append (ein:deps--package-requires) ein:deps--test-only))
        (failed nil))
    (unless (cl-every #'package-installed-p wanted)
      (package-refresh-contents))
    (dolist (pkg wanted)
      (unless (package-installed-p pkg)
        (condition-case err
            (package-install pkg)
          (error (push (cons pkg err) failed)))))
    (if failed
        (progn
          (dolist (f failed)
            (message "install-deps: FAILED %s: %S" (car f) (cdr f)))
          (kill-emacs 1))
      (message "install-deps: OK %s -> %s" wanted package-user-dir)
      (kill-emacs 0))))

(when noninteractive
  (ein:deps-install))

(provide 'install-deps)
;;; install-deps.el ends here
