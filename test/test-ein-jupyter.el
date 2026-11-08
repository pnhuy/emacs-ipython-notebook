;;; test-ein-jupyter.el --- Tests for ein-jupyter -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-jupyter.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-jupyter.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-jupyter.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T028: server subcommand auto-detection.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-jupyter)

(defmacro ein:testing-with-probe (exit-code &rest body)
  "Run BODY with `call-process' returning EXIT-CODE; bind `probes'."
  (declare (indent 1))
  `(let ((probes 0)
         (ein:jupyter--detected-subcommand nil))
     (cl-letf (((symbol-function 'call-process)
                (lambda (&rest _) (cl-incf probes) ,exit-code)))
       ,@body)))

(ert-deftest ein:jupyter-kernelspec-choices-without-shell ()
  "Kernelspecs are read without a shell and despite stderr noise.
With fish as login shell, a leading \"2>/dev/null\" made the old
query fail with (json-unknown-keyword fish)."
  (let* ((dir (make-temp-file "ein-fake-jupyter-" t))
         (fake (expand-file-name "fake-jupyter" dir))
         (shell-file-name "/nonexistent/fish"))
    (unwind-protect
        (progn
          (with-temp-file fake
            (insert "#!/bin/sh\n"
                    "echo 'fish: warning on stderr' >&2\n"
                    "[ \"$1 $2 $3\" = 'kernelspec list --json' ] || exit 2\n"
                    "echo '{\"kernelspecs\": {\"python3\": "
                    "{\"spec\": {\"display_name\": \"Python 3\"}}}}'\n"))
          (set-file-modes fake #o700)
          (should (equal (ein:jupyter--kernelspec-choices fake)
                         '((python3 . "Python 3")))))
      (delete-directory dir t))))

(ert-deftest ein:jupyter-kernelspec-choices-missing-command ()
  (should-not (ein:jupyter--kernelspec-choices "/nonexistent/jupyter")))

(ert-deftest ein:jupyter-detect-subcommand-server ()
  (let ((ein:jupyter-server-use-subcommand nil))
    (ein:testing-with-probe 0
      (should (equal (ein:jupyter--detect-subcommand) "server")))))

(ert-deftest ein:jupyter-detect-subcommand-notebook ()
  (let ((ein:jupyter-server-use-subcommand nil))
    (ein:testing-with-probe 1
      (should (equal (ein:jupyter--detect-subcommand) "notebook")))))

(ert-deftest ein:jupyter-detect-subcommand-explicit ()
  (let ((ein:jupyter-server-use-subcommand "server"))
    (ein:testing-with-probe 1
      (should (equal (ein:jupyter--detect-subcommand) "server"))
      (should (= probes 0)))))

(ert-deftest ein:jupyter-detect-subcommand-cached ()
  (let ((ein:jupyter-server-use-subcommand nil))
    (ein:testing-with-probe 0
      (ein:jupyter--detect-subcommand)
      (ein:jupyter--detect-subcommand)
      (should (= probes 1)))))

(provide 'test-ein-jupyter)
;;; test-ein-jupyter.el ends here
