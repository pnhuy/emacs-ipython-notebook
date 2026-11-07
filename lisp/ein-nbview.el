;;; ein-nbview.el --- Cell-based notebook view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-nbview.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-nbview.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-nbview.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The cells view (`ein:notebook-view' = `cells'): one ordinary buffer
;; holding every cell's source, edited in place.  Each cell is
;;
;;   [H][source ...][F]
;;
;; where H (header) and F (footer) are single read-only,
;; cursor-intangible "\n" characters carrying the properties
;; `ein-nbview-cell' (the cell object) and `ein-nbview-part'
;; (`header' or `footer').  Everything the user sees around the source
;; -- prompt, rules, outputs -- is the `display' property of H and F,
;; so the buffer text between H and F is exactly the cell source
;; (specs/004-modernize-ein-ui/data-model.md §8).  Because cells are
;; plain text with properties, structural edits are ordinary buffer
;; edits and undo restores them, cell object and all.
;;
;; Stickiness: H is front-sticky and rear-nonsticky, F is front-nonsticky
;; and rear-sticky.  So text can be typed anywhere inside a source
;; (also into an empty one, between H and F) but not between cells nor
;; before the first or after the last cell.
;;
;; Display-only updates (prompt, outputs, decorations) change text
;; properties inside `with-silent-modifications', so they never reach
;; the undo list nor mark the buffer modified.

;;; Code:

(require 'eieio)
(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'ein-core)
(require 'ein-classes)
(require 'ein-log)
(require 'ein-view)
(require 'ein-cell)
(require 'ein-kill-ring)
(require 'ein-nbview-edit)
(require 'ein-nbview-markdown)
(require 'ein-nbview-output)
(require 'ein-nbview-toolbar)
(require 'ein-completer)

(declare-function ein:kernel-when-ready "ein-kernel")
(declare-function ein:notebook-save-notebook-command "ein-notebook")
(declare-function ein:notebook-kernel-interrupt-command "ein-notebook")
(declare-function ein:notebook-reconnect-session-command "ein-notebook")
(declare-function ein:notebook-restart-session-command "ein-notebook")
(declare-function ein:notebook-rename-command "ein-notebook")
(defvar ein:%worksheet%)
(defvar ein:%notebook%)
(declare-function ein:jupyter-running-notebook-directory "ein-jupyter")

;;; Customization

(defgroup ein-nbview nil
  "The cell-based notebook view."
  :group 'ein)

(defcustom ein:nbview-cell-spacing 1
  "Blank display lines between cells."
  :type 'natnum
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-cell-bar
  '((t :inherit shadow))
  "Left bar of unselected cells."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-cell-bar-selected
  '((t :inherit highlight :background unspecified))
  "Left bar of the selected cell."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-cell-bar-editing
  '((((class color) (min-colors 88))
     :inherit success :weight bold :inverse-video t)
    ;; Few colours: `highlight' (the selected bar) may share the hue.
    (t :weight bold :inverse-video t))
  "Left bar of the cell being edited."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-cell-rule
  '((t :inherit shadow))
  "Top and bottom rules of a cell."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-code-face
  '((((class color) (min-colors 88) (background light))
     :background "#f4f4f4" :extend t)
    (((class color) (min-colors 88) (background dark))
     :background "#1e1e1e" :extend t)
    (t :inherit default))
  "Background of code cell sources."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-markdown-face
  '((t :inherit default))
  "Markdown cell sources (no background, as in VS Code)."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-prompt
  '((t :inherit shadow))
  "Execution count `[n]' and running indicator `[*]'."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-output-face
  '((t :inherit default))
  "Plain-text outputs."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-stderr-face
  '((t :inherit warning))
  "Standard error outputs."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defface ein:nbview-error-face
  '((t :inherit error))
  "Error outputs (tracebacks)."
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defconst ein:nbview-placeholder-text
  "Empty notebook — press b (or C-c C-b) to add a cell"
  "What an empty notebook shows instead of cells.")

;;; The view

(defclass ein:nbview (ein:view)
  ((buffer :initarg :buffer :documentation "The notebook buffer.")
   (worksheet :initarg :worksheet :initform nil
              :documentation "The `ein:worksheet' whose cells are shown.")
   (markers :initform (make-hash-table :test #'eq)
            :documentation "Cell -> marker at its header; validated on use.")
   (selected :initform nil :documentation "The selected cell.")
   (overlay :initform nil :documentation "The selection overlay."))
  "The cell-based view.")

(defvar-local ein:nbview--view nil
  "The `ein:nbview' of the current buffer.")
(put 'ein:nbview--view 'permanent-local t)

(defvar-local ein:nbview--editing nil
  "Non-nil while the selected cell is in edit state.")

(defvar-local ein:nbview--bar-cell nil
  "The cell whose output string shows the selection bar.")

(defun ein:nbview--current-view ()
  "Return the current buffer's `ein:nbview', or signal a `user-error'."
  (or ein:nbview--view (user-error "Not in a notebook cells view")))

;;; Display strings

(defun ein:nbview--rule-char ()
  "Return the rule character for this display."
  (if (char-displayable-p ?─) ?─ ?-))

(defun ein:nbview--bar (face)
  "Return the left bar string in FACE."
  (propertize (if (char-displayable-p ?▎) "▎ " "| ") 'face face))

(defun ein:nbview--rule-width ()
  "Width of the cell rules, from the buffer's window when it has one."
  (let ((w (get-buffer-window (current-buffer) t)))
    (max 10 (- (if w (window-body-width w) 80) 12))))

(defun ein:nbview--rule (&optional shorten)
  "Return a horizontal rule string, SHORTEN columns narrower."
  (propertize (make-string (max 3 (- (ein:nbview--rule-width) (or shorten 0)))
                           (ein:nbview--rule-char))
              'face 'ein:nbview-cell-rule))

(defun ein:nbview--label (cell)
  "Return the header label of CELL: its prompt, or its type."
  (propertize
   (cond
    ((ein:codecell-p cell)
     (let ((n (ein:oref-safe cell 'input-prompt-number)))
       (cond ((or (ein:oref-safe cell 'running) (equal n "*")) "[*]")
             ((numberp n) (format "[%d]" n))
             (t "[ ]"))))
    ((ein:markdowncell-p cell) "Markdown")
    ((ein:rawcell-p cell) "Raw")
    (t (capitalize (format "%s" (slot-value cell 'cell-type)))))
   'face 'ein:nbview-prompt))

(defun ein:nbview--header-display (cell)
  "Return the `display' string of CELL's header.
The selected (or hovered) cell's header ends with its toolbar."
  (let* ((toolbar (and (ein:nbview--cell-toolbar-p cell) (ein:nbview--cell-toolbar)))
         (s (concat (make-string ein:nbview-cell-spacing ?\n)
                    (ein:nbview--label cell) " "
                    (ein:nbview--rule (if toolbar (1+ (string-width toolbar)) 0))
                    (if toolbar (concat " " toolbar) "")
                    "\n")))
    ;; A click on a toolbar button acts on this cell.
    (add-text-properties 0 (length s) (list 'ein-nbview-cell cell) s)
    s))

(defun ein:nbview--string (value)
  "Return VALUE, a string or a sequence of strings, as one string."
  (cond ((stringp value) value)
        ((sequencep value) (mapconcat (lambda (s) (format "%s" s)) value ""))
        ((null value) "")
        (t (format "%s" value))))

(defvar-local ein:nbview--expanded-outputs nil
  "Weak hash table of the cells whose outputs are shown untruncated.")

(defun ein:nbview--outputs-expanded-p (cell)
  "Non-nil when CELL's outputs are shown untruncated."
  (and ein:nbview--expanded-outputs
       (gethash cell ein:nbview--expanded-outputs)))

(defun ein:nbview--set-outputs-expanded (view cell flag)
  "Show CELL's outputs in VIEW untruncated when FLAG is non-nil."
  (with-current-buffer (oref view buffer)
    (unless ein:nbview--expanded-outputs
      (setq ein:nbview--expanded-outputs
            (make-hash-table :test #'eq :weakness 'key)))
    (if flag
        (puthash cell t ein:nbview--expanded-outputs)
      (remhash cell ein:nbview--expanded-outputs))
    (ein:nbview--render-footer view cell)))

(defun ein:nbview--output-context (view cell)
  "Rendering context of CELL's outputs in VIEW (see `ein:nbview-render-output')."
  (let ((window (get-buffer-window (oref view buffer) t)))
    (list :graphic (display-graphic-p (and window (window-frame window)))
          :window-width (if window (window-body-width window t) 800)
          :window-cols (if window (window-body-width window) 80)
          :notebook-dir (ein:nbview--notebook-directory)
          :cell cell
          :on-update (lambda ()
                       (when (buffer-live-p (oref view buffer))
                         (ein:nbview--render-footer view cell))))))

(defun ein:nbview--footer-body (view cell)
  "Return what VIEW shows below CELL's source: its outputs, then a rule."
  (let ((outputs (and (ein:codecell-p cell) (ein:oref-safe cell 'outputs))))
    (concat
     (cond ((null outputs) "")
           ((ein:oref-safe cell 'collapsed)
            (propertize "[outputs hidden]\n" 'face 'ein:nbview-prompt))
           (t (let ((s (ein:nbview-render-outputs
                        outputs (ein:nbview--output-context view cell))))
                (if (ein:nbview--outputs-expanded-p cell)
                    s
                  (ein:nbview-output-truncate
                   s ein:nbview-output-max-lines
                   (lambda () (ein:nbview--set-outputs-expanded view cell t)))))))
     (ein:nbview--rule) "\n")))

(defun ein:nbview--header-string (cell)
  "Return CELL's header character."
  (propertize "\n" 'read-only t 'cursor-intangible t
              'ein-nbview-cell cell 'ein-nbview-part 'header
              'front-sticky t 'rear-nonsticky t
              'help-echo #'ein:nbview--header-help
              'display (ein:nbview--header-display cell)))

(defun ein:nbview--footer-string (cell)
  "Return CELL's footer character.
What shows below the source is the `before-string' of an overlay on it
\(see `ein:nbview--render-footer')."
  (propertize "\n" 'read-only t 'cursor-intangible t
              'ein-nbview-cell cell 'ein-nbview-part 'footer))

(defun ein:nbview--placeholder-string ()
  "Return the empty-notebook placeholder character."
  (propertize "\n" 'read-only t 'cursor-intangible t
              'ein-nbview-part 'placeholder 'front-sticky t
              'display ein:nbview-placeholder-text))

;;; Positions

(defun ein:nbview--scan (view)
  "Return VIEW's cells in buffer order and refresh the position markers."
  (with-current-buffer (oref view buffer)
    (let ((markers (oref view markers))
          (pos (point-min))
          cells)
      (maphash (lambda (_cell m) (set-marker m nil)) markers)
      (clrhash markers)
      (while (setq pos (text-property-any pos (point-max) 'ein-nbview-part 'header))
        (let ((cell (get-text-property pos 'ein-nbview-cell)))
          (push cell cells)
          (puthash cell (copy-marker pos) markers))
        (setq pos (1+ pos)))
      (nreverse cells))))

(defun ein:nbview--header-pos (view cell)
  "Return the position of CELL's header in VIEW's buffer, or nil.
Nil means CELL is not in the buffer (deleted)."
  (with-current-buffer (oref view buffer)
    (cl-flet ((valid (m) (and m (marker-position m)
                              (eq (get-text-property m 'ein-nbview-cell) cell)
                              (eq (get-text-property m 'ein-nbview-part) 'header)
                              (marker-position m))))
      (or (valid (gethash cell (oref view markers)))
          (progn (ein:nbview--scan view)
                 (valid (gethash cell (oref view markers))))))))

(defun ein:nbview--footer-pos (header)
  "Return the position of the footer that closes the cell at HEADER."
  (text-property-any (1+ header) (point-max) 'ein-nbview-part 'footer))

(defun ein:nbview--source-bounds (view cell)
  "Return (BEG . END) of CELL's source in VIEW's buffer, or nil."
  (with-current-buffer (oref view buffer)
    (when-let* ((h (ein:nbview--header-pos view cell))
                (f (ein:nbview--footer-pos h)))
      (cons (1+ h) f))))

(defun ein:nbview--cell-at (&optional pos)
  "Return the cell at POS (default point) in the current buffer, or nil."
  (setq pos (or pos (point)))
  (or (get-text-property pos 'ein-nbview-cell)
      (and (> pos (point-min)) (get-text-property (1- pos) 'ein-nbview-cell))
      (let ((p (previous-single-property-change pos 'ein-nbview-part)))
        (and p (> p (point-min)) (get-text-property (1- p) 'ein-nbview-cell)))))

(defun ein:nbview--check-invariants (&optional view)
  "Signal an error unless VIEW's buffer satisfies data-model.md §8 1-4.
Return t otherwise.  VIEW defaults to the current buffer's view."
  (setq view (or view (ein:nbview--current-view)))
  (with-current-buffer (oref view buffer)
    (let ((pos (point-min))
          (expect 'header)
          (seen (make-hash-table :test #'eq))
          open cells)
      (while (< pos (point-max))
        (let ((part (get-text-property pos 'ein-nbview-part))
              (cell (get-text-property pos 'ein-nbview-cell)))
          (cond
           ((null part)
            (setq pos (next-single-property-change pos 'ein-nbview-part nil (point-max))))
           (t
            (pcase part
              ('placeholder nil)
              ('header
               (unless (eq expect 'header)
                 (error "Invariant 1: header at %d, expected footer" pos))
               (when (gethash cell seen)
                 (error "Invariant 3: cell at %d appears twice" pos))
               (puthash cell t seen)
               (push cell cells)
               (setq open (cons cell pos) expect 'footer))
              ('footer
               (unless (eq expect 'footer)
                 (error "Invariant 1: footer at %d, expected header" pos))
               (unless (eq cell (car open))
                 (error "Invariant 1: footer at %d closes another cell" pos))
               (when (text-property-not-all (1+ (cdr open)) pos 'ein-nbview-cell nil)
                 (error "Invariant 2: source of cell at %d has cell properties"
                        (cdr open)))
               (setq expect 'header))
              (_ (error "Unknown part %S at %d" part pos)))
            (setq pos (1+ pos))))))
      (unless (eq expect 'header)
        (error "Invariant 1: last header has no footer"))
      (unless (equal (nreverse cells) (ein:view-cells view))
        (error "Invariant 4: model order differs from buffer order"))
      t)))

;;; Rendering

(defmacro ein:nbview--with-structural-change (&rest body)
  "Run BODY as one atomic, amalgamated undo group with read-only lifted."
  (declare (indent 0) (debug t))
  (let ((group (make-symbol "group"))
        (ok (make-symbol "ok")))
    `(let ((,group (prepare-change-group))
           (,ok nil)
           (inhibit-read-only t))
       (unwind-protect
           (progn
             (activate-change-group ,group)
             (prog1 (progn ,@body) (setq ,ok t)))
         (if ,ok
             (progn (accept-change-group ,group)
                    (undo-amalgamate-change-group ,group))
           (cancel-change-group ,group))))))

(defun ein:nbview--render-cell (view cell pos)
  "Insert CELL as header, source and footer at POS in VIEW's buffer."
  (with-current-buffer (oref view buffer)
    (setf (slot-value cell 'view) view)
    (save-excursion
      (goto-char pos)
      (insert (ein:nbview--header-string cell)
              (or (ein:oref-safe cell 'input) "")
              (ein:nbview--footer-string cell)))
    (puthash cell (copy-marker pos) (oref view markers))
    (ein:nbview--render-footer view cell)))

(defun ein:nbview--set-part-display (view cell part display)
  "Set PART (header or footer) of CELL to DISPLAY, silently.
Do nothing when CELL is not in the buffer."
  (with-current-buffer (oref view buffer)
    (when-let* ((h (ein:nbview--header-pos view cell))
                (pos (if (eq part 'header) h (ein:nbview--footer-pos h))))
      (with-silent-modifications
        (put-text-property pos (1+ pos) 'display display)))))

(defun ein:nbview--render-header (view cell)
  "Re-render CELL's header (prompt, status) in VIEW."
  (ein:nbview--set-part-display view cell 'header (ein:nbview--header-display cell)))

(defun ein:nbview--footer-overlay (view cell &optional create)
  "Return the overlay showing CELL's outputs in VIEW.
CREATE non-nil makes it when missing.  Nil when CELL is not shown."
  (with-current-buffer (oref view buffer)
    (when-let* ((h (ein:nbview--header-pos view cell))
                (f (ein:nbview--footer-pos h)))
      (or (cl-find-if (lambda (o) (eq (overlay-get o 'ein-nbview-footer) cell))
                      (overlays-at f))
          (and create
               ;; Front-advance: text typed at the end of the source
               ;; stays out of it.  It evaporates with the footer.
               (let ((ov (make-overlay f (1+ f) nil t nil)))
                 (overlay-put ov 'ein-nbview-footer cell)
                 (overlay-put ov 'evaporate t)
                 ov))))))

(defun ein:nbview--apply-footer-bar (view cell ov)
  "Set OV's `before-string' to CELL's footer body with its left bar.
The string starts with the newline that ends the source's last line and
leaves out the body's final newline, which the footer character
supplies.  So every line of it starts inside the string and takes its
`line-prefix': a line starting in the buffer would take the prefix of
the text after the footer (the next cell, or none at the end).  A
leading space with a `cursor' property keeps point at the footer drawn
at the end of the source instead of after the outputs (a newline gets
no cursor glyph)."
  (let* ((face (if (eq cell (oref view selected))
                   (ein:nbview--selection-face)
                 'ein:nbview-cell-bar))
         (bar (ein:nbview--bar face))
         (body (or (overlay-get ov 'ein-nbview-body) ""))
         (s (concat " \n" (string-remove-suffix "\n" body))))
    (add-text-properties 0 (length s)
                         (list 'line-prefix bar 'wrap-prefix bar
                               'ein-nbview-cell cell)
                         s)
    (put-text-property 0 1 'cursor t s)
    (overlay-put ov 'before-string s)))

(defun ein:nbview--render-footer (view cell)
  "Re-render CELL's footer (outputs, bottom rule) in VIEW.
Outputs are an overlay string: Emacs ignores image `display' properties
nested in a `display' string, and overlays never touch the undo list.
See `ein:nbview--apply-footer-bar' for its shape."
  (with-current-buffer (oref view buffer)
    (when-let* ((ov (ein:nbview--footer-overlay view cell t)))
      (overlay-put ov 'ein-nbview-body (ein:nbview--footer-body view cell))
      (ein:nbview--apply-footer-bar view cell ov))))

(defun ein:nbview--footer-rendered (view cell)
  "The string VIEW shows below CELL's source, or nil.
It is the footer body, as `ein:nbview--footer-body' returns it."
  (when-let* ((ov (ein:nbview--footer-overlay view cell))
              (s (overlay-get ov 'before-string)))
    (concat (substring s 2) "\n")))

(defun ein:nbview--remove-placeholder ()
  "Delete the empty-notebook placeholder, if any."
  (let ((inhibit-read-only t))
    (when-let* ((p (text-property-any (point-min) (point-max)
                                      'ein-nbview-part 'placeholder)))
      (delete-region p (1+ p)))))

(defun ein:nbview--ensure-placeholder ()
  "Insert the placeholder when the buffer shows no cell."
  (unless (text-property-not-all (point-min) (point-max) 'ein-nbview-part nil)
    (let ((inhibit-read-only t))
      (delete-region (point-min) (point-max))
      (save-excursion
        (goto-char (point-min))
        (insert (ein:nbview--placeholder-string))))))

;;; Decorations

(defun ein:nbview--add-face (beg end face)
  "Append FACE to the `face' of BEG..END where it is missing."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'face nil end)))
        (unless (memq face (ensure-list (get-text-property pos 'face)))
          (add-face-text-property pos next face t))
        (setq pos next)))))

(defun ein:nbview--decorate-cell (view cell)
  "Apply CELL's bar and background in VIEW's buffer (display only)."
  (with-current-buffer (oref view buffer)
    (when-let* ((h (ein:nbview--header-pos view cell))
                (f (ein:nbview--footer-pos h)))
      (with-silent-modifications
        (let ((bar (ein:nbview--bar 'ein:nbview-cell-bar)))
          (put-text-property h (1+ f) 'line-prefix bar)
          (put-text-property h (1+ f) 'wrap-prefix bar))
        (when (and (ein:codecell-p cell) (< (1+ h) f))
          (ein:nbview--add-face (1+ h) f 'ein:nbview-code-face))))))

(defun ein:nbview--cells-in (beg end)
  "Cells whose region intersects BEG..END in the current buffer, in order."
  (let ((cells (ensure-list (ein:nbview--cell-at beg)))
        (pos beg))
    (while (and (< pos end)
                (setq pos (text-property-any pos end 'ein-nbview-part 'header)))
      (push (get-text-property pos 'ein-nbview-cell) cells)
      (setq pos (1+ pos)))
    (nreverse (delete-dups cells))))

(defun ein:nbview--jit-decorate (beg end)
  "`jit-lock' function: decorate the cells between BEG and END."
  (when-let* ((view ein:nbview--view))
    (dolist (cell (ein:nbview--cells-in beg end))
      (ein:nbview--decorate-cell view cell))))

(defun ein:nbview--selection-face ()
  "Bar face of the selected cell for the current state."
  (if ein:nbview--editing 'ein:nbview-cell-bar-editing 'ein:nbview-cell-bar-selected))

(defun ein:nbview--update-selection-overlay (view)
  "Move VIEW's selection overlay onto its selected cell."
  (with-current-buffer (oref view buffer)
    (let* ((ov (or (oref view overlay)
                   (setf (oref view overlay)
                         (let ((o (make-overlay (point-min) (point-min) nil nil t)))
                           (overlay-put o 'ein-nbview-selection t)
                           (overlay-put o 'priority 10)
                           o))))
           (cell (oref view selected))
           (h (and cell (ein:nbview--header-pos view cell)))
           (f (and h (ein:nbview--footer-pos h))))
      (let ((bar (ein:nbview--bar (ein:nbview--selection-face))))
        (overlay-put ov 'line-prefix bar)
        (overlay-put ov 'wrap-prefix bar))
      (if f
          (move-overlay ov h (1+ f))
        (move-overlay ov (point-min) (point-min)))
      ;; The output strings carry their own bar.
      (let ((prev ein:nbview--bar-cell))
        (setq ein:nbview--bar-cell cell)
        (dolist (c (delete-dups (delq nil (list prev cell))))
          (when-let* ((fov (ein:nbview--footer-overlay view c)))
            (ein:nbview--apply-footer-bar view c fov)))))))

(defun ein:nbview-set-editing (flag)
  "Show the selected cell as being edited when FLAG is non-nil."
  (setq ein:nbview--editing flag)
  (when ein:nbview--view
    (ein:nbview--update-selection-overlay ein:nbview--view)))

(defun ein:nbview--post-command ()
  "Select the cell at point when it changed."
  (when-let* ((view ein:nbview--view))
    (condition-case err
        (let ((cell (ein:nbview--cell-at (point))))
          (unless (eq cell (oref view selected))
            (ein:view-select-cell view cell)))
      (error (ein:log 'warn "ein:nbview--post-command: %s"
                      (error-message-string err))))))

;;; Markdown preview

(defcustom ein:nbview-markdown-preview t
  "Non-nil: show inactive Markdown cells rendered.
The rendering is display only; the buffer and the notebook keep the
Markdown source.  `ein:nbview-toggle-markdown-preview' changes it for
one buffer."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defun ein:nbview--preview-overlay (view cell)
  "The overlay previewing CELL in VIEW's buffer, or nil."
  (with-current-buffer (oref view buffer)
    (when-let* ((b (ein:nbview--source-bounds view cell)))
      (cl-find-if (lambda (ov) (and (overlay-get ov 'ein-nbview-preview)
                                    (= (overlay-start ov) (car b))
                                    (= (overlay-end ov) (cdr b))))
                  (overlays-in (car b) (cdr b))))))

(defun ein:nbview--delete-previews (beg end)
  "Delete the preview overlays within BEG..END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'ein-nbview-preview)
      (delete-overlay ov))))

(defun ein:nbview--notebook-directory ()
  "Local directory of the current notebook, when the server is local."
  (when-let* ((root (and (fboundp 'ein:jupyter-running-notebook-directory)
                         (ein:jupyter-running-notebook-directory)))
              (nb (bound-and-true-p ein:%notebook%))
              (path (ignore-errors (ein:$notebook-notebook-path nb))))
    (let ((dir (expand-file-name (or (file-name-directory path) "") root)))
      (and (file-directory-p dir) dir))))

(defun ein:nbview--preview-context (view cell)
  "Rendering context of CELL in VIEW (see `ein:nbview-render-markdown')."
  (let ((window (get-buffer-window (oref view buffer) t)))
    (list :graphic (display-graphic-p (and window (window-frame window)))
          :window-width (if window (window-body-width window t) 800)
          :notebook-dir (ein:nbview--notebook-directory)
          :attachments (plist-get (ein:oref-safe cell 'raw) :attachments)
          :owner cell
          :refresh (lambda ()
                     (when (buffer-live-p (oref view buffer))
                       (with-current-buffer (oref view buffer)
                         (when (ein:nbview--preview-overlay view cell)
                           (ein:nbview--refresh-preview view cell))))))))

(defun ein:nbview--refresh-preview (view cell &optional leaving)
  "Show or hide the Markdown preview of CELL in VIEW.
The preview shows when it is enabled, CELL is a non-empty Markdown cell
and CELL is not being edited.  LEAVING non-nil means CELL is leaving
edit state.  A renderer error shows the source in
`ein:nbview-md-error' and is logged; editing is unaffected."
  (with-current-buffer (oref view buffer)
    (when-let* ((b (ein:nbview--source-bounds view cell)))
      (ein:nbview--delete-previews (car b) (cdr b))
      (if (and ein:nbview-markdown-preview
               (ein:markdowncell-p cell)
               (< (car b) (cdr b))
               (or leaving
                   (not (and (eq ein:nbview--state 'edit)
                             (eq cell (oref view selected))))))
          (let ((ov (make-overlay (car b) (cdr b) nil t nil))
                (source (buffer-substring-no-properties (car b) (cdr b))))
            (overlay-put ov 'ein-nbview-preview t)
            (overlay-put ov 'evaporate t)
            (condition-case err
                ;; Hide the source and show the rendering before it.  A
                ;; `display' string would not do: Emacs ignores the
                ;; image `display' properties nested inside it.
                (let ((render (ein:nbview-render-markdown
                               source (ein:nbview--preview-context view cell))))
                  (overlay-put ov 'before-string render)
                  (overlay-put ov 'invisible t))
              (error
               (ein:log 'warn "Markdown preview failed: %s" (error-message-string err))
               (overlay-put ov 'face 'ein:nbview-md-error))))
        (ein:latex-cancel cell)))))

(defun ein:nbview--refresh-all-previews (view)
  "Refresh the preview of every cell of VIEW."
  (dolist (cell (ein:view-cells view))
    (ein:nbview--refresh-preview view cell)))

(defun ein:nbview--preview-leave-edit ()
  "`ein:nbview-leave-edit-hook' function: preview the cell being left."
  (when-let* ((view ein:nbview--view)
              (cell ein:nbview--selected))
    (ein:nbview--refresh-preview view cell t)))

(defun ein:nbview--preview-enter-edit ()
  "`ein:nbview-enter-edit-hook' function: show the source of the edited cell."
  (when-let* ((view ein:nbview--view)
              (cell ein:nbview--selected))
    (ein:nbview--refresh-preview view cell)))

(defun ein:nbview-toggle-markdown-preview ()
  "Toggle the Markdown preview in this notebook buffer."
  (interactive)
  (setq-local ein:nbview-markdown-preview (not ein:nbview-markdown-preview))
  (ein:nbview--refresh-all-previews (ein:nbview--current-view))
  (message "Markdown preview %s" (if ein:nbview-markdown-preview "on" "off")))

;;; Protocol methods

(cl-defmethod ein:view-buffer ((view ein:nbview))
  (let ((buffer (oref view buffer)))
    (and (buffer-live-p buffer) buffer)))

(cl-defmethod ein:view-render-notebook ((view ein:nbview) _notebook)
  "Insert every saved cell of VIEW's worksheet; nothing executes."
  (with-current-buffer (oref view buffer)
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (ws (oref view worksheet)))
      (erase-buffer)
      (dolist (cell (and ws (slot-value ws 'saved-cells)))
        (ein:nbview--render-cell view cell (point-max)))
      (ein:nbview--ensure-placeholder)
      (ein:nbview--refresh-all-previews view))
    (goto-char (point-min))
    (when-let* ((first (car (ein:view-cells view)))
                (bounds (ein:nbview--source-bounds view first)))
      (goto-char (car bounds)))
    (ein:view-select-cell view (ein:nbview--cell-at (point)))))

(cl-defmethod ein:view-cells ((view ein:nbview))
  (if (buffer-live-p (oref view buffer))
      (ein:nbview--scan view)
    (and (oref view worksheet) (slot-value (oref view worksheet) 'saved-cells))))

(cl-defmethod ein:view-cell-text ((view ein:nbview) cell)
  "Return CELL's source from the buffer and store it in its `input'."
  (let ((bounds (and (buffer-live-p (oref view buffer))
                     (ein:nbview--source-bounds view cell))))
    (if bounds
        (setf (slot-value cell 'input)
              (with-current-buffer (oref view buffer)
                (buffer-substring-no-properties (car bounds) (cdr bounds))))
      (or (ein:oref-safe cell 'input) ""))))

(cl-defmethod ein:view-set-cell-text ((view ein:nbview) cell text)
  (if-let* ((bounds (and (buffer-live-p (oref view buffer))
                         (ein:nbview--source-bounds view cell))))
      (with-current-buffer (oref view buffer)
        (save-excursion
          (goto-char (car bounds))
          (delete-region (car bounds) (cdr bounds))
          (insert text))
        (ein:nbview--refresh-preview view cell))
    (setf (slot-value cell 'input) text)))

(defcustom ein:nbview-output-coalesce-delay 0.05
  "Seconds during which further output changes of a cell are batched.
The first change renders at once; later ones within the delay render
once when it expires."
  :type 'number
  :package-version '(ein . "0.18")
  :group 'ein-nbview)

(defvar-local ein:nbview--output-timers nil
  "Hash table: cell -> (TIMER . PENDING) of its coalescing window.")

(defun ein:nbview--output-timer-fired (view cell)
  "End CELL's coalescing window in VIEW; render if changes are pending.
A trailing render opens a new window, so a steady stream renders at
most once per `ein:nbview-output-coalesce-delay'."
  (when-let* ((buffer (ein:view-buffer view)))
    (with-current-buffer buffer
      (when-let* ((timers ein:nbview--output-timers)
                  (entry (gethash cell timers)))
        (remhash cell timers)
        (when (cdr entry)
          (puthash cell (cons (run-with-timer ein:nbview-output-coalesce-delay nil
                                              #'ein:nbview--output-timer-fired view cell)
                              nil)
                   timers)
          (condition-case err
              (ein:nbview--render-footer view cell)
            (error (ein:log 'warn "ein:nbview output render: %s"
                            (error-message-string err)))))))))

(defun ein:nbview--cancel-output-timers ()
  "Cancel the coalescing timers of the current buffer."
  (when ein:nbview--output-timers
    (maphash (lambda (_cell entry) (cancel-timer (car entry)))
             ein:nbview--output-timers)
    (clrhash ein:nbview--output-timers)))

(cl-defmethod ein:view-cell-outputs-changed ((view ein:nbview) cell &optional _index)
  "Re-render CELL's footer, coalescing bursts of changes.
Never signals (process filters call it)."
  (condition-case err
      (when-let* ((buffer (ein:view-buffer view)))
        (with-current-buffer buffer
          (let ((timers (or ein:nbview--output-timers
                            (setq ein:nbview--output-timers
                                  (make-hash-table :test #'eq)))))
            (if-let* ((entry (gethash cell timers)))
                (setcdr entry t)
              (puthash cell (cons (run-with-timer ein:nbview-output-coalesce-delay nil
                                                  #'ein:nbview--output-timer-fired view cell)
                                  nil)
                       timers)
              (ein:nbview--render-footer view cell)))))
    (error (ein:log 'warn "ein:view-cell-outputs-changed: %s"
                    (error-message-string err)))))

(cl-defmethod ein:view-cell-status-changed ((view ein:nbview) cell)
  "Re-render CELL's header.  Never signals (process filters call it)."
  (condition-case err
      (when (buffer-live-p (oref view buffer))
        (ein:nbview--render-header view cell))
    (error (ein:log 'warn "ein:view-cell-status-changed: %s"
                    (error-message-string err)))))

(cl-defmethod ein:view-insert-cell ((view ein:nbview) cell &optional after-cell)
  (with-current-buffer (oref view buffer)
    (ein:nbview--with-structural-change
      (ein:nbview--remove-placeholder)
      (let ((pos (if-let* ((after-cell)
                           (h (ein:nbview--header-pos view after-cell)))
                     (1+ (ein:nbview--footer-pos h))
                   (point-min))))
        (ein:nbview--render-cell view cell pos)))
    (ein:nbview--refresh-preview view cell)
    cell))

(cl-defmethod ein:view-delete-cell ((view ein:nbview) cell)
  (with-current-buffer (oref view buffer)
    (when-let* ((h (ein:nbview--header-pos view cell))
                (f (ein:nbview--footer-pos h)))
      (ein:view-cell-text view cell)    ; keep its text for undo-less users
      (ein:nbview--delete-previews h (1+ f))
      (ein:latex-cancel cell)
      (ein:nbview--with-structural-change
        (delete-region h (1+ f))
        (ein:nbview--ensure-placeholder)))))

(cl-defmethod ein:view-move-cell ((view ein:nbview) cell direction)
  "Move CELL one place in DIRECTION (`up' or `down'); keep point in it."
  (with-current-buffer (oref view buffer)
    (let* ((h (ein:nbview--header-pos view cell))
           (f (and h (ein:nbview--footer-pos h)))
           (offset (and f (<= (1+ h) (point) f) (- (point) h)))
           (other (and f (if (eq direction 'up)
                             (and (> h (point-min)) (get-text-property (1- h) 'ein-nbview-cell))
                           (and (< (1+ f) (point-max)) (get-text-property (1+ f) 'ein-nbview-cell))))))
      (when other
        (ein:nbview--with-structural-change
          ;; Moving CELL down is moving OTHER up: the region moved is
          ;; always the lower cell, reinserted before the upper one.
          (let* ((upper (if (eq direction 'up) other cell))
                 (lower (if (eq direction 'up) cell other))
                 (uh (ein:nbview--header-pos view upper))
                 (lh (ein:nbview--header-pos view lower))
                 (lf (ein:nbview--footer-pos lh))
                 (text (buffer-substring lh (1+ lf))))
            (delete-region lh (1+ lf))
            (goto-char uh)
            (insert text)
            (ein:nbview--scan view)))
        (when offset
          (goto-char (+ (ein:nbview--header-pos view cell) offset)))
        ;; Reinsertion collapsed the overlay if it covered the lower cell,
        ;; and the lower cell's output overlay evaporated.
        (ein:nbview--render-footer view cell)
        (ein:nbview--render-footer view other)
        (ein:nbview--update-selection-overlay view)
        (ein:nbview--refresh-preview view cell)
        (ein:nbview--refresh-preview view other)
        t))))

(cl-defmethod ein:view-replace-cell ((view ein:nbview) old new)
  "Replace OLD by NEW in place; point keeps its offset in the source."
  (with-current-buffer (oref view buffer)
    (when-let* ((h (ein:nbview--header-pos view old))
                (f (ein:nbview--footer-pos h)))
      (let ((offset (and (<= (1+ h) (point) f) (- (point) h))))
        (setf (slot-value new 'input) (ein:view-cell-text view old))
        (ein:nbview--delete-previews h (1+ f))
        (ein:latex-cancel old)
        (ein:nbview--with-structural-change
          (delete-region h (1+ f))
          (ein:nbview--render-cell view new h))
        (when offset (goto-char (+ h offset)))
        (when (eq (oref view selected) old)
          (setf (oref view selected) nil)
          (ein:view-select-cell view new))
        (ein:nbview--refresh-preview view new)
        new))))

(cl-defmethod ein:view-select-cell ((view ein:nbview) cell)
  "Select CELL: move the selection overlay, redecorate old and new cell."
  (let ((old (oref view selected)))
    (setf (oref view selected) cell)
    (when (buffer-live-p (oref view buffer))
      (with-current-buffer (oref view buffer)
        (ein:nbview--selection-changed ein:nbview--selected cell))
      (ein:nbview--update-selection-overlay view)
      (when old (ein:nbview--decorate-cell view old))
      (when (and cell (not (eq cell old)))
        (ein:nbview--decorate-cell view cell))
      ;; The cell toolbar follows the selection.
      (when (and ein:nbview-cell-toolbar (not (eq cell old)))
        (when old (ein:nbview--render-header view old))
        (when cell (ein:nbview--render-header view cell))))))

;;; Commands

(defun ein:nbview--cell-or-error ()
  "Return the cell at point or signal a `user-error'."
  (or (ein:nbview--cell-at (point)) (user-error "No cell here")))

(defun ein:nbview--goto-source (view cell &optional end)
  "Move point to the start (END non-nil: the end) of CELL's source."
  (when-let* ((bounds (ein:nbview--source-bounds view cell)))
    (goto-char (if end (cdr bounds) (car bounds)))
    (ein:view-select-cell view cell)))

(defun ein:nbview--new-cell (view type)
  "Return a new empty cell of TYPE (a string) for VIEW's worksheet."
  (let* ((ws (oref view worksheet))
         (cell (ein:cell-from-type type
                                   :events (and ws (slot-value ws 'events))
                                   :view view)))
    (when (and ws (ein:codecell-p cell))
      (setf (slot-value cell 'kernel) (slot-value ws 'kernel)))
    (setf (slot-value cell 'input) "")
    cell))

(defun ein:nbview--set-dirty (view)
  "Mark VIEW's worksheet as changed."
  (when-let* ((ws (oref view worksheet)))
    (setf (slot-value ws 'dirty) t)))

(defun ein:nbview-select-cell (cell)
  "Select CELL and move point to its source."
  (interactive (list (ein:nbview--cell-or-error)))
  (ein:nbview--goto-source (ein:nbview--current-view) cell))

(defun ein:nbview-next-cell (&optional n)
  "Move to the source of the Nth next cell (default 1)."
  (interactive "p")
  (let* ((view (ein:nbview--current-view))
         (cells (ein:view-cells view))
         (i (cl-position (ein:nbview--cell-at (point)) cells))
         (j (if i (+ i (or n 1)) 0)))
    (if-let* ((cell (and (>= j 0) (nth j cells))))
        (ein:nbview--goto-source view cell)
      (user-error (if (< j 0) "No previous cell" "No next cell")))))

(defun ein:nbview-previous-cell (&optional n)
  "Move to the source of the Nth previous cell (default 1)."
  (interactive "p")
  (ein:nbview-next-cell (- (or n 1))))

(defun ein:nbview-insert-cell-below (&optional type)
  "Insert a cell of TYPE (default code) below the current cell.
With a prefix argument, insert a markdown cell.  In an empty notebook
the new cell is the first one."
  (interactive (list (if current-prefix-arg "markdown" "code")))
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--new-cell view (or type "code"))))
    (ein:view-insert-cell view cell (ein:nbview--cell-at (point)))
    (ein:nbview--set-dirty view)
    (ein:nbview--goto-source view cell)
    cell))

(defun ein:nbview-insert-cell-above (&optional type)
  "Insert a cell of TYPE (default code) above the current cell.
With a prefix argument, insert a markdown cell."
  (interactive (list (if current-prefix-arg "markdown" "code")))
  (let* ((view (ein:nbview--current-view))
         (here (ein:nbview--cell-at (point)))
         (h (and here (ein:nbview--header-pos view here)))
         (prev (and h (> h (point-min)) (get-text-property (1- h) 'ein-nbview-cell)))
         (cell (ein:nbview--new-cell view (or type "code"))))
    (ein:view-insert-cell view cell prev)
    (ein:nbview--set-dirty view)
    (ein:nbview--goto-source view cell)
    cell))

(defun ein:nbview-delete-cell ()
  "Delete the current cell.  Undo restores it with its outputs."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error))
         (h (ein:nbview--header-pos view cell))
         (next (let ((f (ein:nbview--footer-pos h)))
                 (and (< (1+ f) (point-max)) (get-text-property (1+ f) 'ein-nbview-cell))))
         (prev (and (> h (point-min)) (get-text-property (1- h) 'ein-nbview-cell))))
    (ein:view-delete-cell view cell)
    (ein:nbview--set-dirty view)
    (if-let* ((target (or next prev)))
        (ein:nbview--goto-source view target)
      (goto-char (point-min))
      (ein:view-select-cell view nil))))

(defun ein:nbview-move-cell-up ()
  "Move the current cell up."
  (interactive)
  (let ((view (ein:nbview--current-view)))
    (unless (ein:view-move-cell view (ein:nbview--cell-or-error) 'up)
      (user-error "First cell"))
    (ein:nbview--set-dirty view)))

(defun ein:nbview-move-cell-down ()
  "Move the current cell down."
  (interactive)
  (let ((view (ein:nbview--current-view)))
    (unless (ein:view-move-cell view (ein:nbview--cell-or-error) 'down)
      (user-error "Last cell"))
    (ein:nbview--set-dirty view)))

(defun ein:nbview--convert (type)
  "Convert the current cell to TYPE (a string)."
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error)))
    (unless (equal (slot-value cell 'cell-type) type)
      (ein:view-cell-text view cell)
      (let ((new (ein:cell-convert cell type))
            (ws (oref view worksheet)))
        (when ws
          (setf (slot-value new 'events) (slot-value ws 'events))
          (when (ein:codecell-p new)
            (setf (slot-value new 'kernel) (slot-value ws 'kernel))))
        (ein:view-replace-cell view cell new)
        (ein:nbview--set-dirty view)
        new))))

(defun ein:nbview-to-markdown ()
  "Convert the current cell to a markdown cell."
  (interactive)
  (ein:nbview--convert "markdown"))

(defun ein:nbview-to-code ()
  "Convert the current cell to a code cell."
  (interactive)
  (ein:nbview--convert "code"))

(defun ein:nbview-toggle-cell-type ()
  "Convert a code cell to Markdown, and any other cell to code."
  (interactive)
  (ein:nbview--convert (if (ein:codecell-p (ein:nbview--cell-or-error)) "markdown" "code")))

(defun ein:nbview-copy-cell ()
  "Copy the current cell to the EIN cell kill ring.
The copy keeps the cell's type, source, outputs and metadata as they
are now; yank it with \\[ein:nbview-yank-cell]."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error)))
    (ein:view-cell-text view cell)
    (ein:kill-new (list (ein:cell-convert cell (slot-value cell 'cell-type))))
    (message "Cell copied")))

(defun ein:nbview-cut-cell ()
  "Copy the current cell to the EIN cell kill ring, then delete it."
  (interactive)
  (ein:nbview-copy-cell)
  (ein:nbview-delete-cell))

(defun ein:nbview-yank-cell (&optional n)
  "Insert the last copied cell below the current cell.
With prefix argument N, insert the Nth most recent copy instead, as
`yank' does.  The inserted cell gets a new id."
  (interactive (list (let ((arg current-prefix-arg))
                       (cond ((listp arg) 0)
                             ((eq arg '-) -2)
                             (t (1- arg))))))
  (unless ein:kill-ring (user-error "No copied cell"))
  (let* ((view (ein:nbview--current-view))
         (ws (oref view worksheet))
         (last (ein:nbview--cell-at (point))))
    (dolist (c (ein:current-kill (or n 0)))
      (let ((clone (ein:cell-convert c (slot-value c 'cell-type))))
        (setf (slot-value clone 'cell-id)
              (ein:cell--fresh-id
               (mapcar (lambda (x) (slot-value x 'cell-id)) (ein:view-cells view)))
              (slot-value clone 'view) view)
        (when ws
          (setf (slot-value clone 'events) (slot-value ws 'events))
          (when (ein:codecell-p clone)
            (setf (slot-value clone 'kernel) (slot-value ws 'kernel))))
        (ein:view-insert-cell view clone last)
        (setq last clone)))
    (ein:nbview--set-dirty view)
    (ein:nbview--goto-source view last)
    last))

(defun ein:nbview-show-traceback ()
  "Show the current cell's error output, with its full traceback."
  (interactive)
  (let ((cell (ein:nbview--cell-or-error)))
    (unless (and (ein:codecell-p cell)
                 (cl-some (lambda (o)
                            (member (plist-get o :output_type) '("error" "pyerr")))
                          (slot-value cell 'outputs)))
      (user-error "No traceback in this cell"))
    (ein:nbview-output-view)))

(defun ein:nbview--skip-newlines (pos limit backward)
  "Move POS over newlines towards LIMIT (BACKWARD: down to it); return it."
  (if backward
      (while (and (> pos limit) (eq (char-before pos) ?\n)) (cl-decf pos))
    (while (and (< pos limit) (eq (char-after pos) ?\n)) (cl-incf pos)))
  pos)

(defun ein:nbview-split-cell ()
  "Split the current cell at point; the text after point becomes a new cell.
Newlines around point are dropped.  The upper part keeps the cell's
id, metadata and outputs; the lower part is a new cell with a new id.
One undo step reverts the split."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error))
         (bounds (ein:nbview--source-bounds view cell))
         (pos (min (max (point) (car bounds)) (cdr bounds)))
         (head-end (ein:nbview--skip-newlines pos (car bounds) t))
         (tail-beg (ein:nbview--skip-newlines pos (cdr bounds) nil))
         (new (ein:nbview--new-cell view (slot-value cell 'cell-type))))
    (setf (slot-value new 'view) view)
    (ein:nbview--with-structural-change
      ;; Later position first so that HEAD-END and TAIL-BEG stay valid.
      (goto-char (cdr bounds))
      (delete-char 1)
      (insert (ein:nbview--footer-string new))
      (delete-region head-end tail-beg)
      (goto-char head-end)
      (insert (ein:nbview--footer-string cell) (ein:nbview--header-string new)))
    (ein:nbview--scan view)
    (ein:nbview--set-dirty view)
    (ein:nbview--render-footer view cell)
    (ein:nbview--render-footer view new)
    (ein:nbview--decorate-cell view cell)
    (ein:nbview--goto-source view new)
    new))

(defun ein:nbview-merge-cell (&optional above)
  "Merge the cell below into the current cell.
With prefix argument ABOVE, merge the current cell into the cell above.
The upper cell keeps its id, metadata and outputs; the sources are
joined by a newline.  One undo step reverts the merge."
  (interactive "P")
  (let* ((view (ein:nbview--current-view))
         (here (ein:nbview--cell-or-error))
         (cells (ein:view-cells view))
         (i (cl-position here cells))
         (upper (if above (and (> i 0) (nth (1- i) cells)) here))
         (lower (if above here (nth (1+ i) cells))))
    (unless (and upper lower)
      (user-error (if above "No cell above" "No cell below")))
    (let* ((ub (ein:nbview--source-bounds view upper))
           (lb (ein:nbview--source-bounds view lower))
           (offset (and (<= (car ub) (point) (cdr ub)) (- (point) (car ub))))
           (sep (if (or (= (car ub) (cdr ub)) (= (car lb) (cdr lb))) "" "\n")))
      (ein:nbview--with-structural-change
        (goto-char (cdr lb))
        (delete-char 1)
        (insert (ein:nbview--footer-string upper))
        ;; Upper footer and lower header become the separator.
        (delete-region (cdr ub) (car lb))
        (goto-char (cdr ub))
        (insert sep)
        (with-silent-modifications
          (remove-list-of-text-properties (cdr ub) (+ (cdr ub) (length sep)
                                                      (- (cdr lb) (car lb)))
                                          '(face))))
      (ein:nbview--scan view)
      (ein:nbview--set-dirty view)
      (ein:nbview--render-footer view upper)
      (ein:nbview--decorate-cell view upper)
      (goto-char (+ (car ub) (or offset (- (cdr ub) (car ub)))))
      (setf (oref view selected) nil)
      (ein:view-select-cell view upper)
      upper)))

(defun ein:nbview-run-cell ()
  "Execute the current code cell.  Its outputs appear below it.
In edit state, leave it (see `ein:nbview-modal')."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error)))
    (ein:nbview-command-state)
    (ein:view-cell-text view cell)
    (if (not (ein:codecell-p cell))
        (unless (ein:markdowncell-p cell) (message "Not a code cell"))
      (ein:kernel-when-ready
       (slot-value cell 'kernel)
       (lambda (_kernel)
         (ein:cell-execute cell)
         (ein:nbview--set-dirty view))))))

;;; Output and input visibility

(defun ein:nbview--code-cell-or-error ()
  "Return the code cell at point or signal a `user-error'."
  (let ((cell (ein:nbview--cell-or-error)))
    (unless (ein:codecell-p cell) (user-error "Not a code cell"))
    cell))

(defun ein:nbview-toggle-output ()
  "Hide or show the outputs of the current code cell.
Saved as `metadata.jupyter.outputs_hidden'."
  (interactive)
  (let ((view (ein:nbview--current-view))
        (cell (ein:nbview--code-cell-or-error)))
    (ein:cell-set-collapsed cell (not (slot-value cell 'collapsed)))
    (ein:nbview--render-footer view cell)
    (ein:nbview--set-dirty view)))

(defun ein:nbview-toggle-output-truncation ()
  "Show all outputs of the current cell, or truncate them again.
See `ein:nbview-output-max-lines'."
  (interactive)
  (let ((view (ein:nbview--current-view))
        (cell (ein:nbview--cell-or-error)))
    (ein:nbview--set-outputs-expanded
     view cell (not (ein:nbview--outputs-expanded-p cell)))))

(defun ein:nbview--input-overlay (view cell)
  "The overlay hiding CELL's source in VIEW, or nil."
  (when-let* ((b (ein:nbview--source-bounds view cell)))
    (cl-find-if (lambda (o) (eq (overlay-get o 'ein-nbview-input-hidden) cell))
                (overlays-in (car b) (cdr b)))))

(defun ein:nbview--show-input (view cell)
  "Show CELL's source in VIEW if it is hidden."
  (when-let* ((ov (ein:nbview--input-overlay view cell)))
    (delete-overlay ov)))

(defun ein:nbview-toggle-input ()
  "Hide or show the source of the current cell (display only).
Editing the cell shows its source again."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error))
         (b (ein:nbview--source-bounds view cell)))
    (if (ein:nbview--input-overlay view cell)
        (ein:nbview--show-input view cell)
      (when (< (car b) (cdr b))
        (let ((ov (make-overlay (car b) (cdr b))))
          (overlay-put ov 'ein-nbview-input-hidden cell)
          (overlay-put ov 'evaporate t)
          (overlay-put ov 'invisible t)
          (overlay-put ov 'before-string
                       (propertize "[source hidden]" 'face 'ein:nbview-prompt)))))))

(defun ein:nbview--input-enter-edit ()
  "`ein:nbview-enter-edit-hook' function: show the edited cell's source."
  (when-let* ((view ein:nbview--view)
              (cell ein:nbview--selected))
    (ein:nbview--show-input view cell)))

(defun ein:nbview-clear-output ()
  "Delete the outputs of the current code cell."
  (interactive)
  (let ((view (ein:nbview--current-view))
        (cell (ein:nbview--code-cell-or-error)))
    (ein:cell-clear-output cell t t t)
    (ein:nbview--render-footer view cell)
    (ein:nbview--set-dirty view)))

(defun ein:nbview-clear-all-output ()
  "Delete the outputs of every code cell."
  (interactive)
  (let ((view (ein:nbview--current-view)))
    (dolist (cell (ein:view-cells view))
      (when (ein:codecell-p cell)
        (ein:cell-clear-output cell t t t)
        (ein:nbview--render-footer view cell)))
    (ein:nbview--set-dirty view)))

;;; Undo
;;
;; The buffer is the model: headers and footers carry their cell
;; object, so the ordinary undo list restores text, cells, their order
;; and their identity.  Display updates (prompts, outputs, decorations)
;; never enter it.  The wrappers below only lift read-only text and
;; repair stale displays afterwards.

(defvar-local ein:nbview--undo-region nil
  "Markers (BEG . END) around the changes made by the running undo.")

(defun ein:nbview--record-undo-change (beg end _len)
  "`after-change-functions' recorder active during the undo wrappers."
  (let ((r ein:nbview--undo-region))
    (if (null r)
        (setq ein:nbview--undo-region (cons (copy-marker beg) (copy-marker end t)))
      (when (< beg (car r)) (set-marker (car r) beg))
      (when (> end (cdr r)) (set-marker (cdr r) end)))))

(defun ein:nbview--reconcile (beg end)
  "Repair the cells view after an undo changed BEG..END.
Refresh the header and footer display of every cell in the range (they
may be stale copies from the undo list), redecorate those cells,
rescan the cell positions and select the cell at point."
  (when-let* ((view ein:nbview--view))
    (let ((pos (max (point-min) (1- beg)))
          (end (min (point-max) (1+ end)))
          (cells (delq nil (list (ein:nbview--cell-at beg) (ein:nbview--cell-at end)))))
      (while (< pos end)
        (when-let* ((cell (get-text-property pos 'ein-nbview-cell)))
          (push cell cells))
        (setq pos (next-single-property-change pos 'ein-nbview-cell nil end)))
      (ein:nbview--scan view)
      (dolist (cell (delete-dups cells))
        (ein:nbview--render-header view cell)
        (ein:nbview--render-footer view cell)
        (ein:nbview--decorate-cell view cell))
      (ein:nbview--set-dirty view)
      (setf (oref view selected) nil)
      (ein:view-select-cell view (ein:nbview--cell-at (point)))
      (dolist (cell cells)
        (ein:nbview--refresh-preview view cell)))))

(defun ein:nbview--call-undo (fn arg)
  "Call the undo command FN with ARG across read-only cell boundaries."
  (let ((inhibit-read-only t))
    (setq ein:nbview--undo-region nil)
    (add-hook 'after-change-functions #'ein:nbview--record-undo-change nil t)
    (unwind-protect
        (funcall fn arg)
      (remove-hook 'after-change-functions #'ein:nbview--record-undo-change t)
      (when-let* ((r ein:nbview--undo-region))
        (setq ein:nbview--undo-region nil)
        (ein:nbview--reconcile (car r) (cdr r))
        (set-marker (car r) nil)
        (set-marker (cdr r) nil)))))

(defun ein:nbview-undo (&optional arg)
  "Undo, including cell insertion, deletion, movement and conversion.
ARG is as for `undo'."
  (interactive "*P")
  (ein:nbview--call-undo #'undo arg))

(defun ein:nbview-undo-only (&optional arg)
  "Undo without redoing, across cell operations.  ARG is as for `undo-only'."
  (interactive "*p")
  (ein:nbview--call-undo #'undo-only arg))

(defun ein:nbview-undo-redo (&optional arg)
  "Redo the last undone change, including cell operations.
ARG is as for `undo-redo'."
  (interactive "*p")
  (ein:nbview--call-undo #'undo-redo arg))

(defun ein:nbview--assert-no-undo-entries (fn &optional buffer)
  "Call FN and signal an error if it added entries to BUFFER's undo list.
BUFFER defaults to the current buffer.  Return FN's value."
  (with-current-buffer (or buffer (current-buffer))
    (let ((before buffer-undo-list))
      (prog1 (funcall fn)
        (unless (eq before buffer-undo-list)
          (error "Undo entries added: %S"
                 (cl-ldiff buffer-undo-list before)))))))

;;; Mode

(defvar-keymap ein:nbview-mode-map
  :doc "Keymap of `ein:nbview-mode'."
  "C-c C-c" #'ein:nbview-run-cell
  "C-x C-s" #'ein:notebook-save-notebook-command
  "C-c C-a" #'ein:nbview-insert-cell-above
  "C-c C-b" #'ein:nbview-insert-cell-below
  "C-c C-k" #'ein:nbview-delete-cell
  "C-c C-n" #'ein:nbview-next-cell
  "C-c C-p" #'ein:nbview-previous-cell
  "C-c <up>" #'ein:nbview-move-cell-up
  "C-c <down>" #'ein:nbview-move-cell-down
  "C-c C-s" #'ein:nbview-split-cell
  "C-c RET" #'ein:nbview-merge-cell
  "C-c C-t" #'ein:nbview-toggle-cell-type
  "C-c C-w" #'ein:nbview-copy-cell
  "C-c C-y" #'ein:nbview-yank-cell
  "C-c C-$" #'ein:nbview-show-traceback
  "C-c C-v" #'ein:nbview-toggle-markdown-preview
  "C-c C-e" #'ein:nbview-toggle-output
  "C-c C-l" #'ein:nbview-clear-output
  "C-c C-S-l" #'ein:nbview-clear-all-output
  "C-c C-o" #'ein:nbview-output-map
  "M-RET" #'ein:nbview-run-and-advance
  "C-c C-z" #'ein:notebook-kernel-interrupt-command
  "C-c C-r" #'ein:notebook-reconnect-session-command
  "C-c C-x C-r" #'ein:notebook-restart-session-command
  "C-c C-x C-k" #'ein:nbview-select-kernel
  "C-c C-f" #'ein:nbview-run-all
  "C-x C-w" #'ein:notebook-rename-command
  "<mouse-1>" #'ein:nbview-mouse-select
  "<remap> <undo>" #'ein:nbview-undo
  "<remap> <undo-only>" #'ein:nbview-undo-only
  "<remap> <undo-redo>" #'ein:nbview-undo-redo
  "RET" #'ein:nbview-newline
  "TAB" #'ein:nbview-indent-or-complete)

(define-derived-mode ein:nbview-mode nil "EIN"
  "Major mode of a notebook in the cells view.

\\{ein:nbview-mode-map}"
  (cursor-intangible-mode 1)
  (setq-local yank-excluded-properties
              (delete-dups
               (append '(read-only cursor-intangible ein-nbview-cell ein-nbview-part
                                   display line-prefix wrap-prefix face
                                   font-lock-face syntax-table)
                       (and (listp yank-excluded-properties) yank-excluded-properties))))
  (setq-local truncate-lines nil)
  (setq-local font-lock-defaults
              '(nil t nil nil
                    (font-lock-fontify-region-function . ein:nbview--fontify-region)
                    (font-lock-unfontify-region-function . ein:nbview--unfontify-region)))
  (setq-local indent-line-function #'ein:nbview-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local syntax-propertize-function #'ein:nbview--syntax-propertize)
  (setq-local parse-sexp-lookup-properties t)
  (add-hook 'completion-at-point-functions #'ein:nbview-completion-at-point nil t)
  (add-hook 'kill-buffer-hook #'ein:nbview--kill-shadow-buffers nil t)
  (add-hook 'kill-buffer-hook #'ein:nbview--cancel-output-timers nil t)
  (add-hook 'ein:nbview-enter-edit-hook #'ein:nbview--input-enter-edit nil t)
  (jit-lock-register #'ein:nbview--jit-decorate)
  (add-hook 'post-command-hook #'ein:nbview--post-command nil t)
  (add-hook 'ein:nbview-enter-edit-hook #'ein:nbview--preview-enter-edit nil t)
  (add-hook 'ein:nbview-leave-edit-hook #'ein:nbview--preview-leave-edit nil t)
  (setq buffer-undo-list nil))

(defun ein:nbview-open (notebook ws buffer)
  "Show worksheet WS of NOTEBOOK in BUFFER in the cells view; return the view."
  (with-current-buffer buffer
    (ein:nbview-mode)
    (ein:nbview-edit-setup notebook)
    (let ((view (make-instance 'ein:nbview :buffer buffer :worksheet ws)))
      (setq ein:nbview--view view)
      (setf (ein:worksheet--view ws) view)
      (setq ein:%worksheet% ws)
      (ein:view-render-notebook view notebook)
      (ein:nbview-modes-setup)
      (when-let* ((cell (oref view selected)))
        (ein:nbview--refresh-preview view cell))
      (set-buffer-modified-p nil)
      (setq buffer-undo-list nil)
      view)))

(provide 'ein-nbview)

;;; ein-nbview.el ends here
