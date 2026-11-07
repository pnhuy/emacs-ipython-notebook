;;; test-ein-fixtures.el --- Tests for the fixture and nbformat helpers -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-fixtures.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-fixtures.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-fixtures.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Sanity tests for test/ein-testing-nbformat.el and
;; `ein:testing-notebook-from-file'.

;;; Code:

(require 'ert)
(require 'ein-testing-nbformat)
(require 'ein-testing-notebook)

(ert-deftest ein:testing-json-semantic-equal-ignores-order-and-form ()
  (should (ein:testing-json-semantic-equal
           "{\"a\": 1, \"source\": [\"x\\n\", \"y\"]}"
           "{\"source\": \"x\\ny\", \"a\": 1}"))
  (should-not (ein:testing-json-semantic-equal
               "{\"a\": 1}" "{\"a\": 2}"))
  (should-not (ein:testing-json-semantic-equal
               "{\"a\": null}" "{\"a\": false}")))

(ert-deftest ein:testing-nbformat-validate-smoke ()
  (should (ein:testing-nbformat-validate (ein:testing-fixture "smoke.ipynb"))))

(ert-deftest ein:testing-nbformat-validate-rejects-invalid ()
  (should-error
   (ein:testing-nbformat-validate
    (expand-file-name "invalid/cells-not-list.ipynb" ein:testing-fixtures-dir))
   :type 'ert-test-failed))

(ert-deftest ein:testing-notebook-from-file-smoke ()
  (let ((buffer (ein:testing-notebook-from-file (ein:testing-fixture "smoke.ipynb"))))
    (unwind-protect
        (with-current-buffer buffer
          (let ((cells (ein:worksheet-get-cells ein:%worksheet%)))
            (should (= (length cells) 2))
            (should (equal (ein:cell-get-text (nth 1 cells))
                           "import os\nprint(os.sep)"))))
      (let ((kill-buffer-query-functions nil))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(provide 'test-ein-fixtures)
;;; test-ein-fixtures.el ends here
