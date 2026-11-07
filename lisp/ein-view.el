;;; ein-view.el --- Notebook view protocol -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-view.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-view.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-view.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The boundary between the notebook model (cells, kernel callbacks,
;; serialization) and its presentation.  The model calls only the
;; `ein:view-' generics below; a view implements them.
;;
;; Two views exist:
;;  - `ein:classic-view' wraps the original ewoc + polymode buffer.
;;    Classic cells keep rendering through their ewoc nodes (their
;;    `view' slot is nil), so the classic behaviour is unchanged.
;;  - `ein:nbview' (ein-nbview.el), the cell-based view.
;;
;; Obligations (specs/004-modernize-ein-ui/contracts/view-protocol.md):
;;  1. `ein:view-cell-outputs-changed' and `ein:view-cell-status-changed'
;;     may run from process filters: no errors, no point or window
;;     motion, no undo entries.
;;  2. A deleted cell keeps receiving outputs in its `outputs' slot;
;;     rendering is skipped.
;;  3. Serialization obtains cells and text only through
;;     `ein:view-cells' and `ein:view-cell-text'.
;;  4. The cost of a single-cell notification does not depend on the
;;     number of cells.

;;; Code:

(require 'eieio)
(require 'cl-lib)

(declare-function ein:worksheet-get-cells "ein-worksheet")
(declare-function ein:worksheet--ewoc-buffer "ein-worksheet")
(declare-function ein:worksheet-insert-cell-below "ein-worksheet")
(declare-function ein:worksheet-insert-cell-above "ein-worksheet")
(declare-function ein:worksheet-delete-cell "ein-worksheet")
(declare-function ein:worksheet-move-cell "ein-worksheet")
(declare-function ein:worksheet-goto-input "ein-worksheet")
(declare-function ein:cell-get-text "ein-cell")
(declare-function ein:cell-goto "ein-cell")

(defclass ein:view ()
  ()
  "A presentation of a notebook's cells in a buffer."
  :abstract t)

(defclass ein:classic-view (ein:view)
  ((worksheet :initarg :worksheet
              :documentation "The `ein:worksheet' rendered by ewoc."))
  "The original ewoc + polymode view, behind the protocol.")

;;; Protocol

(cl-defgeneric ein:view-render-notebook (view notebook)
  "Populate VIEW's buffer from NOTEBOOK's cells.  Called once on open.")

(cl-defgeneric ein:view-cells (view)
  "Return the cells of VIEW in display order (buffer order for nbview).")

(cl-defgeneric ein:view-cell-text (view cell)
  "Return CELL's current source text (from the buffer region in nbview).")

(cl-defgeneric ein:view-cell-outputs-changed (view cell &optional output-index)
  "Re-render CELL's outputs.  Must not touch other cells or the undo list.
OUTPUT-INDEX, when non-nil, is the index of the output just appended.")

(cl-defgeneric ein:view-cell-status-changed (view cell)
  "Update CELL's prompt/execution-count/running indicator.")

(cl-defgeneric ein:view-insert-cell (view cell &optional after-cell)
  "Insert CELL after AFTER-CELL (or at top).  Undoable in nbview.")

(cl-defgeneric ein:view-delete-cell (view cell)
  "Remove CELL.  Undoable in nbview.")

(cl-defgeneric ein:view-move-cell (view cell direction)
  "Move CELL `up' or `down' as one undo group.")

(cl-defgeneric ein:view-replace-cell (view old new)
  "Replace OLD by NEW (type conversion) as one undo group.")

(cl-defgeneric ein:view-select-cell (view cell)
  "Select CELL; update only the old and new cell decorations.")

(cl-defgeneric ein:view-kernel-status-changed (view kernel)
  "Update toolbar/mode-line status for KERNEL."
  (ignore view kernel))

;; Internal helpers used by the model (not in the contract's list).

(cl-defgeneric ein:view-buffer (view)
  "Return VIEW's buffer, or nil when it has none.")

(cl-defgeneric ein:view-set-cell-text (view cell text)
  "Replace CELL's source with TEXT.")

;;; Classic view: delegate to the ewoc code.

(cl-defmethod ein:view-buffer ((view ein:classic-view))
  (ein:worksheet--ewoc-buffer (oref view worksheet)))

(cl-defmethod ein:view-render-notebook ((_view ein:classic-view) _notebook)
  "Rendering stays in `ein:notebook--worksheet-render'."
  nil)

(cl-defmethod ein:view-cells ((view ein:classic-view))
  (ein:worksheet-get-cells (oref view worksheet)))

(cl-defmethod ein:view-cell-text ((view ein:classic-view) cell)
  (let ((buffer (ein:view-buffer view)))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer (ein:cell-get-text cell))
      (ein:cell-get-text cell))))

(cl-defmethod ein:view-cell-outputs-changed ((_view ein:classic-view) _cell &optional _index)
  "Classic cells render outputs through their own ewoc nodes."
  nil)

(cl-defmethod ein:view-cell-status-changed ((_view ein:classic-view) _cell)
  "Classic cells invalidate their prompt node themselves."
  nil)

(cl-defmethod ein:view-insert-cell ((view ein:classic-view) cell &optional after-cell)
  (with-current-buffer (ein:view-buffer view)
    (if after-cell
        (ein:worksheet-insert-cell-below (oref view worksheet) cell after-cell)
      (ein:worksheet-insert-cell-above
       (oref view worksheet) cell
       (car (ein:view-cells view))))))

(cl-defmethod ein:view-delete-cell ((view ein:classic-view) cell)
  (with-current-buffer (ein:view-buffer view)
    (ein:worksheet-delete-cell (oref view worksheet) cell)))

(cl-defmethod ein:view-move-cell ((view ein:classic-view) cell direction)
  (with-current-buffer (ein:view-buffer view)
    (ein:worksheet-move-cell (oref view worksheet) cell (eq direction 'up))))

(cl-defmethod ein:view-select-cell ((view ein:classic-view) cell)
  (with-current-buffer (ein:view-buffer view)
    (ein:cell-goto cell)))

(provide 'ein-view)

;;; ein-view.el ends here
