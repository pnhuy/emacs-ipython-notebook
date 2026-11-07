;;; test-ein-view-equivalence.el --- Classic and cells views save alike -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-view-equivalence.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-view-equivalence.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-view-equivalence.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T081: the same edit script through the classic view and the cells
;; view yields the same notebook JSON (the inserted cell's random id
;; aside).

;;; Code:

(require 'ert)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defun ein:testing-equivalence--json-without-new-id (json new-id)
  "Parse JSON and blank the id NEW-ID, so that it compares stably."
  (let ((data (json-parse-string json :object-type 'alist
                                 :null-object :null :false-object :false)))
    (setf (alist-get 'cells data)
          (cl-map 'vector (lambda (cell)
                            (if (equal (alist-get 'id cell) new-id)
                                (cons '(id . "NEW") (assq-delete-all 'id (copy-alist cell)))
                              cell))
                  (alist-get 'cells data)))
    (ein:testing--normalize-json
     (ein:testing--parse (json-serialize data :null-object :null :false-object :false)))))

(defun ein:testing-equivalence--classic ()
  (let ((ein:notebook-view 'classic))
    (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
      (let* ((ws ein:%worksheet%)
             (cells (ein:worksheet-get-cells ws))
             (new (ein:worksheet-insert-cell-below ws 'code (car cells))))
        (ein:cell-set-text new "x = 1")
        (let ((code (cl-find-if (lambda (c) (and (ein:codecell-p c) (not (eq c new))))
                                (ein:worksheet-get-cells ws))))
          (ein:cell-set-text code (concat (ein:cell-get-text code) " # edited")))
        (ein:worksheet-move-cell-down ws new)
        (let ((last (car (last (ein:worksheet-get-cells ws)))))
          ;; Classic toggling cycles code -> markdown.
          (should (ein:codecell-p last))
          (ein:worksheet-toggle-cell-type ws last))
        (cons (slot-value new 'cell-id)
              (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))))))

(defun ein:testing-equivalence--cells ()
  (let ((ein:notebook-view 'cells))
    (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
      (let* ((view ein:nbview--view)
             (cells (ein:view-cells view)))
        (ein:nbview-select-cell (car cells))
        (let ((new (ein:nbview-insert-cell-below)))
          (insert "x = 1")
          (let* ((code (cl-find-if (lambda (c) (and (ein:codecell-p c) (not (eq c new))))
                                   (ein:view-cells view)))
                 (b (ein:nbview--source-bounds view code)))
            (goto-char (cdr b))
            (insert " # edited"))
          (ein:nbview-select-cell new)
          (ein:nbview-move-cell-down)
          (ein:nbview-select-cell (car (last (ein:view-cells view))))
          (ein:nbview-to-markdown)
          (should (ein:nbview--check-invariants))
          (cons (slot-value new 'cell-id)
                (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%))))))))

(ert-deftest ein:view-equivalence-edit-script ()
  (pcase-let ((`(,classic-id . ,classic) (ein:testing-equivalence--classic))
              (`(,cells-id . ,cells) (ein:testing-equivalence--cells)))
    (should (equal (ein:testing-equivalence--json-without-new-id classic classic-id)
                   (ein:testing-equivalence--json-without-new-id cells cells-id)))))

(provide 'test-ein-view-equivalence)
;;; test-ein-view-equivalence.el ends here
