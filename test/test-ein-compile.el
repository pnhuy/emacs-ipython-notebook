;;; test-ein-compile.el --- Byte-compile every EIN file warning-free -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-compile.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-compile.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-compile.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; SC-001.  Tagged :compile and excluded from the default selector,
;; because `make test-compile' is the primary gate.  Run with:
;;
;;   EIN_TEST_SELECTOR='(tag :compile)' make test-unit

;;; Code:

(require 'ert)
(require 'bytecomp)

(ert-deftest ein:compile-no-warnings ()
  :tags '(:compile)
  (let* ((src (expand-file-name "lisp" default-directory))
         (dir (make-temp-file "ein-compile-" t))
         (failed nil))
    (unwind-protect
        (progn
          (dolist (f (directory-files src t "\\.el\\'"))
            (copy-file f (expand-file-name (file-name-nondirectory f) dir)))
          (let ((load-path (cons dir load-path))
                (byte-compile-error-on-warn t)
                (byte-compile-dest-file-function
                 (lambda (f) (concat (file-name-sans-extension f) ".elc"))))
            (dolist (f (directory-files dir t "\\.el\\'"))
              (unless (ignore-errors (byte-compile-file f))
                (push (file-name-nondirectory f) failed)))))
      (delete-directory dir t))
    (should (equal (nreverse failed) nil))))

(defun ein:testing-compile-alone (files)
  "Compile each of FILES (names in lisp/) in its own fresh Emacs.
Native compilation compiles each file that way.  Return the macros
and `setf' places a file uses without requiring their definitions, as
\(FILE . NAME) pairs: compiled as function calls, they fail at run time."
  (let* ((src (expand-file-name "lisp" default-directory))
         (deps (expand-file-name ".deps/elpa" default-directory))
         (dir (make-temp-file "ein-compile-alone-" t))
         (emacs (expand-file-name invocation-name invocation-directory))
         found)
    (unwind-protect
        (progn
          (dolist (f (directory-files src t "\\.el\\'"))
            (copy-file f (expand-file-name (file-name-nondirectory f) dir)))
          (dolist (file files)
            (with-temp-buffer
              (call-process emacs nil t nil "-Q" "--batch" "-L" dir "--eval"
                            (format "(progn (setq package-user-dir %S) (package-initialize))"
                                    deps)
                            "-f" "batch-byte-compile" (expand-file-name file dir))
              (goto-char (point-min))
              (while (re-search-forward
                      "the function ‘\\([^’]+\\)’ is not known to be defined" nil t)
                (let ((name (match-string 1)))
                  (when (or (string-prefix-p "(setf " name)
                            (macrop (intern-soft name)))
                    (push (cons file name) found)))))))
      (delete-directory dir t))
    (nreverse found)))

(ert-deftest ein:compile-alone-macros ()
  "Natively compiled, the toolbar called the macro `ein:oref-safe'."
  (require 'ein-classes)
  (should-not (ein:testing-compile-alone
               '("ein-nbview-toolbar.el" "ein-shared-output.el"))))

(ert-deftest ein:compile-alone-all ()
  "No file needs another file loaded first to expand its macros."
  :tags '(:compile)
  (let ((files (remove "ein-autoloads.el" (directory-files "lisp" nil "\\.el\\'"))))
    (dolist (f files)
      (require (intern (file-name-sans-extension f)) nil t))
    (should-not (ein:testing-compile-alone files))))

(provide 'test-ein-compile)
;;; test-ein-compile.el ends here
