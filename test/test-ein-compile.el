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

(provide 'test-ein-compile)
;;; test-ein-compile.el ends here
