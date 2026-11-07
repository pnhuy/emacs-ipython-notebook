;;; test-ein-view-protocol.el --- Classic view behind the protocol -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-view-protocol.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-view-protocol.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-view-protocol.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T079: with `ein:notebook-view' = `classic', the protocol answers what
;; the ewoc code answers.  The classic suites are the regression guard.

;;; Code:

(require 'ert)
(require 'ein-view)
(require 'ein-notebook)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(ert-deftest ein:view-protocol-classic-cells-and-text ()
  (let ((ein:notebook-view 'classic))
    (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
      (let* ((view (ein:notebook--view ein:%notebook%))
             (cells (ein:worksheet-get-cells ein:%worksheet%)))
        (should (ein:classic-view-p view))
        (should (eq (current-buffer) (ein:view-buffer view)))
        (should cells)
        (should (equal cells (ein:view-cells view)))
        (dolist (cell cells)
          (should (equal (ein:cell-get-text cell)
                         (ein:view-cell-text view cell))))
        ;; Classic cells keep rendering through ewoc.
        (should-not (cl-some (lambda (c) (slot-value c 'view)) cells))
        (should-not (ein:worksheet--view ein:%worksheet%))))))

(ert-deftest ein:view-protocol-classic-text-follows-edits ()
  (let ((ein:notebook-view 'classic))
    (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
      (let* ((view (ein:notebook--view ein:%notebook%))
             (cell (car (ein:view-cells view))))
        (ein:cell-set-text cell "edited = 1")
        (with-temp-buffer
          ;; From another buffer: the view reads the notebook buffer.
          (should (equal "edited = 1" (ein:view-cell-text view cell))))))))

(provide 'test-ein-view-protocol)
;;; test-ein-view-protocol.el ends here
