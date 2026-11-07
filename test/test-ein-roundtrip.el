;;; test-ein-roundtrip.el --- Lossless notebook round-trip tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-roundtrip.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-roundtrip.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-roundtrip.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Contract tests for specs/004-modernize-ein-ui/contracts/notebook-roundtrip.md
;; G2-G9: every corpus notebook opened in EIN and serialized without edits is
;; semantically equal to its input (modulo the G9 normalizations) and still
;; validates with nbformat.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-testing-nbformat)
(require 'ein-testing-notebook)

(defun ein:testing-roundtrip--manifest ()
  "Return the parsed corpus manifest as an alist keyed by file name."
  (with-temp-buffer
    (insert-file-contents (ein:testing-fixture "manifest.json"))
    (json-parse-buffer :object-type 'alist :false-object nil)))

(defun ein:testing-roundtrip--valid-p (name)
  "Non-nil when the manifest says fixture NAME is nbformat-valid."
  (alist-get 'nbformat_valid (alist-get (intern name) (ein:testing-roundtrip--manifest))))

(defun ein:testing-roundtrip--kill (buffer)
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

(defun ein:testing-roundtrip--serialize (path)
  "Open PATH in EIN and return its serialized JSON string (no edits)."
  (let ((buffer (ein:testing-notebook-from-file path)))
    (unwind-protect
        (with-current-buffer buffer
          (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))
      (ein:testing-roundtrip--kill buffer))))

(defun ein:testing-roundtrip--check (name)
  (let* ((path (ein:testing-fixture name))
         (input (with-temp-buffer (insert-file-contents path) (buffer-string)))
         (output (ein:testing-roundtrip--serialize path))
         (file (make-temp-file "ein-roundtrip-" nil ".ipynb")))
    (unwind-protect
        (progn
          (with-temp-file file
            (set-buffer-file-coding-system 'utf-8)
            (insert output))
          (if (equal name "nb44-no-ids.ipynb")
              (let ((parsed (json-parse-string output :object-type 'alist
                                               :array-type 'list)))
                ;; G9(b): ids generated, minor bumped to 5.
                (should (= 5 (alist-get 'nbformat_minor parsed)))
                (dolist (cell (alist-get 'cells parsed))
                  (should (stringp (alist-get 'id cell))))
                (should (ein:testing-json-semantic-equal
                         input (ein:testing-g9-normalize output))))
            (unless (ein:testing-json-semantic-equal input output)
              (ert-fail (list name :input input :output output))))
          (when (ein:testing-roundtrip--valid-p name)
            (ein:testing-nbformat-validate file)))
      (delete-file file))))

(defmacro ein:testing-roundtrip--deftests (&rest names)
  `(progn
     ,@(mapcar
        (lambda (name)
          `(ert-deftest ,(intern (format "ein:roundtrip-%s" (file-name-base name))) ()
             (ein:testing-roundtrip--check ,name)))
        names)))

(ein:testing-roundtrip--deftests
 "attachments.ipynb" "empty.ipynb" "error-output.ipynb" "html-table.ipynb"
 "jupyterlab-style.ipynb" "latex-output.ipynb" "multimime.ipynb"
 "nb44-no-ids.ipynb" "nb46-future.ipynb" "raw-cell.ipynb" "short-id.ipynb"
 "smoke.ipynb" "svg-output.ipynb" "unknown-keys.ipynb" "vscode-style.ipynb"
 "widget-mime.ipynb")

(ert-deftest ein:roundtrip-corpus-is-complete ()
  "Every fixture in the corpus directory has a round-trip test."
  (dolist (file (directory-files (file-name-directory
                                  (ein:testing-fixture "smoke.ipynb"))
                                 nil "\\.ipynb\\'"))
    (should (ert-get-test (intern (format "ein:roundtrip-%s"
                                          (file-name-base file)))))))

(ert-deftest ein:roundtrip-running-count-is-null ()
  "G9(c): a running cell (prompt \"*\") serializes execution_count as null."
  (let ((buffer (ein:testing-notebook-from-file (ein:testing-fixture "smoke.ipynb"))))
    (unwind-protect
        (with-current-buffer buffer
          (let ((cell (cl-find-if (lambda (c) (cl-typep c 'ein:codecell))
                                  (ein:worksheet-get-cells ein:%worksheet%))))
            (setf (slot-value cell 'input-prompt-number) "*")
            (let* ((json (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))
                   (parsed (json-parse-string json :object-type 'alist :array-type 'list
                                              :null-object :null)))
              (should (eq :null (alist-get 'execution_count
                                           (cl-find "code" (alist-get 'cells parsed)
                                                    :key (lambda (c) (alist-get 'cell_type c))
                                                    :test #'equal)))))))
      (ein:testing-roundtrip--kill buffer))))

(provide 'test-ein-roundtrip)
;;; test-ein-roundtrip.el ends here
