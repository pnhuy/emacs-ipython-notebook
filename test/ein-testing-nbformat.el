;;; ein-testing-nbformat.el --- nbformat validation helpers for tests -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-testing-nbformat.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-testing-nbformat.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-testing-nbformat.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `ein:testing-nbformat-validate' runs Python's nbformat validator
;; (skipping the test when nbformat is unavailable).
;; `ein:testing-json-semantic-equal' compares two notebook JSON strings
;; ignoring key order and the string/list form of multiline text.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)

(defconst ein:testing-fixtures-dir
  (expand-file-name
   "fixtures"
   (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding the test fixtures.")

(defun ein:testing-fixture (name)
  "Return the absolute path of round-trip fixture NAME."
  (expand-file-name (concat "roundtrip/" name) ein:testing-fixtures-dir))

(defun ein:testing-nbformat-available-p ()
  "Non-nil when python3 can import nbformat."
  (and (executable-find "python3")
       (zerop (call-process "python3" nil nil nil "-I" "-c" "import nbformat"))))

(defun ein:testing-nbformat-validate (file)
  "Validate FILE with nbformat.  Return t, or signal an ERT failure.
Skip the current test when nbformat is not importable."
  (unless (ein:testing-nbformat-available-p)
    (ert-skip "python3 nbformat not available"))
  (with-temp-buffer
    (let ((status (call-process
                   "python3" nil t nil "-I" "-c"
                   "import nbformat,sys; nbformat.validate(nbformat.read(sys.argv[1],4))"
                   (expand-file-name file))))
      (unless (zerop status)
        (ert-fail (list "nbformat validation failed" file (buffer-string))))
      t)))

(defconst ein:testing--joined-keys '(source text)
  "Keys whose list-of-strings value is equivalent to the joined string.")

(defun ein:testing--normalize-json (value &optional key)
  "Return VALUE with sorted object keys and joined text lists.
KEY is the object key VALUE was found under."
  (cond
   ((and (memq key ein:testing--joined-keys)
         (listp value) (seq-every-p #'stringp value))
    (apply #'concat value))
   ;; Object: alist with symbol keys (json-parse-string :object-type alist).
   ((and (consp value) (consp (car value)) (symbolp (caar value)))
    (sort (mapcar (lambda (kv)
                    (cons (car kv) (ein:testing--normalize-json (cdr kv) (car kv))))
                  value)
          (lambda (a b) (string< (symbol-name (car a)) (symbol-name (car b))))))
   ((listp value)
    (mapcar #'ein:testing--normalize-json value))
   (t value)))

(defun ein:testing--parse (json)
  "Parse JSON (a string) for semantic comparison."
  (json-parse-string json :object-type 'alist :array-type 'list
                     :null-object :null :false-object :false))

(defun ein:testing-json-semantic-equal (a b)
  "Non-nil when JSON strings A and B are semantically equal.
Key order and the string/list form of `source'/`text' are ignored."
  (equal (ein:testing--normalize-json (ein:testing--parse a))
         (ein:testing--normalize-json (ein:testing--parse b))))

(provide 'ein-testing-nbformat)
;;; ein-testing-nbformat.el ends here
