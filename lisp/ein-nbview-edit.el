;;; ein-nbview-edit.el --- Code editing inside cells of the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-nbview-edit.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; ein-nbview-edit.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-nbview-edit.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Language-aware editing of cell sources in the cells view
;; (research.md R4), by shadow-buffer delegation: a hidden buffer per
;; major mode runs the cell language's mode.  A cell's source is
;; copied there to compute
;;
;; - font-lock faces, copied back as text properties,
;; - `syntax-table' properties, so sexp motion and comments work,
;; - the indentation of a line, applied with `indent-line-to'.
;;
;; The notebook buffer keeps one major mode, `ein:nbview-mode'.  No
;; text is changed by fontification or syntax propertization, so
;; neither touches the undo list.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ein-core)
(require 'ein-classes)
(require 'ein-cell)

(declare-function ein:nbview--cells-in "ein-nbview")
(declare-function ein:nbview--cell-at "ein-nbview")
(declare-function ein:nbview--source-bounds "ein-nbview")
(declare-function ein:nbview--decorate-cell "ein-nbview")
(declare-function ein:markdown-mode "ein-markdown-mode")

(defvar ein:nbview--view)
(defvar ein:%notebook%)

(defcustom ein:nbview-language-modes '(("python" . python-mode))
  "Alist of kernel language name to the major mode of its code cells.
The mode fontifies and indents code cells through a hidden shadow
buffer.  `major-mode-remap-alist' is honoured, so a remapping of
`python-mode' to `python-ts-mode' applies.  A language with no
entry uses the mode named LANGUAGE-mode when that is a programming
mode, else `prog-mode'."
  :type '(alist :key-type (string :tag "Language") :value-type (function :tag "Major mode"))
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-native-fontify-max-chars 20000
  "Cells whose source is longer than this many characters are not fontified."
  :type 'natnum
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

;;; Shadow buffers

(defconst ein:nbview--shadow-prefix " *ein-nbview-shadow:"
  "Name prefix of the shadow buffers; the leading space hides them.")

(defun ein:nbview--shadow-buffer (mode)
  "Return the hidden buffer running major MODE, creating it if needed.
The mode's hooks are not run: they belong to files the user visits."
  (let ((name (format "%s%s*" ein:nbview--shadow-prefix mode)))
    (or (get-buffer name)
        (let ((buffer (generate-new-buffer name t)))
          (with-current-buffer buffer
            (setq buffer-undo-list t)
            (condition-case err
                (delay-mode-hooks (funcall mode))
              (error
               (ein:log 'warn "ein:nbview: %s failed in a shadow buffer: %s"
                        mode (error-message-string err))
               (fundamental-mode))))
          buffer))))

(defmacro ein:nbview--in-shadow (mode text &rest body)
  "Run BODY in the shadow buffer of MODE holding TEXT."
  (declare (indent 2) (debug t))
  (let ((str (make-symbol "text")))
    `(let ((,str ,text))
       (with-current-buffer (ein:nbview--shadow-buffer ,mode)
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert ,str)
           ,@body)))))

(defun ein:nbview--kill-shadow-buffers ()
  "Kill the shadow buffers unless another cells-view buffer is alive.
Run from the notebook buffer's `kill-buffer-hook'."
  (let ((self (current-buffer)))
    (unless (cl-some (lambda (b)
                       (and (not (eq b self))
                            (eq 'ein:nbview-mode (buffer-local-value 'major-mode b))))
                     (buffer-list))
      (dolist (b (buffer-list))
        (when (string-prefix-p ein:nbview--shadow-prefix (buffer-name b))
          (kill-buffer b))))))

(defun ein:nbview--shadow-props (prop)
  "List of (BEG END VALUE) for PROP in the current buffer, 0-based."
  (let ((pos (point-min)) acc)
    (while (< pos (point-max))
      (let ((next (next-single-property-change pos prop nil (point-max)))
            (value (get-text-property pos prop)))
        (when value
          (push (list (- pos (point-min)) (- next (point-min)) value) acc))
        (setq pos next)))
    acc))

;;; Languages

(defun ein:nbview--nonempty (value)
  (and (stringp value) (not (string-empty-p value)) value))

(defun ein:nbview--notebook-language (&optional notebook)
  "The kernel language name of NOTEBOOK (default the buffer's notebook).
From `metadata.language_info.name', then `metadata.kernelspec.language',
then the kernelspec's language; \"python\" only when the notebook has no
metadata; else nil."
  (let* ((nb (or notebook ein:%notebook%))
         (md (and (ein:$notebook-p nb) (ein:$notebook-metadata nb)))
         (get (lambda (obj key) (and (consp obj) (plist-get obj key)))))
    (or (ein:nbview--nonempty (funcall get (funcall get md :language_info) :name))
        (ein:nbview--nonempty (funcall get (funcall get md :kernelspec) :language))
        (and (ein:$notebook-p nb)
             (ein:$kernelspec-p (ein:$notebook-kernelspec nb))
             (ein:nbview--nonempty
              (ein:$kernelspec-language (ein:$notebook-kernelspec nb))))
        (and (not (consp md)) "python"))))

(defun ein:nbview--remap-mode (mode)
  "MODE after `major-mode-remap-alist'."
  (if (fboundp 'major-mode-remap)
      (major-mode-remap mode)
    (or (alist-get mode major-mode-remap-alist) mode)))

(defun ein:nbview--programming-mode (symbol)
  "The major mode SYMBOL names, resolving aliases, if it is a `prog-mode'.
Return nil for anything else, such as a minor mode: the name comes from
notebook metadata, which is untrusted."
  (when (and (symbolp symbol) (fboundp symbol))
    (let ((fn symbol))
      (while (and (symbolp (symbol-function fn)) (fboundp (symbol-function fn)))
        (setq fn (symbol-function fn)))
      (when (autoloadp (symbol-function fn))
        (ignore-errors (autoload-do-load (symbol-function fn) fn)))
      (and (provided-mode-derived-p fn 'prog-mode) fn))))

(defun ein:nbview--language-mode (lang)
  "Major mode for code in kernel language LANG."
  (let* ((lang (and (stringp lang) (downcase lang)))
         (entry (and lang (assoc lang ein:nbview-language-modes))))
    (ein:nbview--remap-mode
     (cond ((and entry (fboundp (cdr entry))) (cdr entry))
           ((and lang (ein:nbview--programming-mode (intern-soft (concat lang "-mode")))))
           (t 'prog-mode)))))

(defun ein:nbview--cell-mode (cell)
  "Major mode used to fontify and indent CELL."
  (cond ((ein:codecell-p cell)
         (ein:nbview--language-mode (ein:nbview--notebook-language)))
        ((ein:markdowncell-p cell)
         (require 'ein-markdown-mode)
         'ein:markdown-mode)
        (t 'fundamental-mode)))

(defun ein:nbview-edit-setup (&optional notebook)
  "Set the buffer's comment syntax from NOTEBOOK's language."
  (let ((mode (ein:nbview--language-mode (ein:nbview--notebook-language notebook))))
    (pcase-let ((`(,start ,skip ,end ,end-skip)
                 (with-current-buffer (ein:nbview--shadow-buffer mode)
                   (list comment-start comment-start-skip comment-end comment-end-skip))))
      (setq-local comment-start start
                  comment-start-skip skip
                  comment-end (or end "")
                  comment-end-skip end-skip))))

;;; Font-lock

(defun ein:nbview--fontify-cell (view cell beg end)
  "Fontify CELL's source BEG..END in VIEW's buffer through its shadow buffer."
  (let ((mode (ein:nbview--cell-mode cell)))
    (with-silent-modifications
      (remove-list-of-text-properties beg end '(face font-lock-face))
      (when (and (< beg end)
                 (not (eq mode 'fundamental-mode))
                 (<= (- end beg) ein:nbview-native-fontify-max-chars))
        (let ((text (buffer-substring-no-properties beg end))
              props)
          (ein:nbview--in-shadow mode text
            (let ((font-lock-fontified nil))
              (font-lock-ensure))
            (setq props (nconc (mapcar (lambda (p) (cons 'face p))
                                       (ein:nbview--shadow-props 'face))
                               (mapcar (lambda (p) (cons 'font-lock-face p))
                                       (ein:nbview--shadow-props 'font-lock-face)))))
          (pcase-dolist (`(,prop ,from ,to ,value) props)
            (put-text-property (+ beg from) (+ beg to) prop value))))
      (ein:nbview--decorate-cell view cell))))

(defun ein:nbview--fontify-region (beg end &optional _loudly)
  "`font-lock-fontify-region-function' of the cells view.
Fontify every cell source intersecting BEG..END in its language."
  (let ((lo beg) (hi end))
    (when-let* ((view ein:nbview--view))
      (dolist (cell (ein:nbview--cells-in beg end))
        (when-let* ((b (ein:nbview--source-bounds view cell)))
          (setq lo (min lo (car b)) hi (max hi (cdr b)))
          (ein:nbview--fontify-cell view cell (car b) (cdr b)))))
    `(jit-lock-bounds ,lo . ,hi)))

(defun ein:nbview--unfontify-region (beg end)
  "`font-lock-unfontify-region-function': drop language faces in BEG..END."
  (when-let* ((view ein:nbview--view))
    (dolist (cell (ein:nbview--cells-in beg end))
      (when-let* ((b (ein:nbview--source-bounds view cell)))
        (with-silent-modifications
          (remove-list-of-text-properties (car b) (cdr b) '(face font-lock-face)))
        (ein:nbview--decorate-cell view cell)))))

;;; Syntax

(defun ein:nbview--syntax-propertize (start end)
  "`syntax-propertize-function': give cell sources their language syntax.
Each source intersecting START..END gets its mode's syntax table as a
`syntax-table' property, plus the mode's own syntax properties."
  (when-let* ((view ein:nbview--view))
    (dolist (cell (ein:nbview--cells-in start end))
      (when-let* ((b (ein:nbview--source-bounds view cell)))
        (let* ((beg (car b)) (fin (cdr b))
               (mode (ein:nbview--cell-mode cell))
               (small (<= (- fin beg) ein:nbview-native-fontify-max-chars))
               table props)
          (ein:nbview--in-shadow mode (if small (buffer-substring-no-properties beg fin) "")
            (setq table (syntax-table))
            (when small
              (syntax-propertize (point-max))
              (setq props (ein:nbview--shadow-props 'syntax-table))))
          (with-silent-modifications
            (put-text-property beg fin 'syntax-table table)
            (pcase-dolist (`(,from ,to ,value) props)
              (put-text-property (+ beg from) (+ beg to) 'syntax-table value))))))))

;;; Indentation

(defun ein:nbview-indent-line ()
  "`indent-line-function' of the cells view.
Indent the current line of a cell source as its language mode would,
computed in the shadow buffer.  Other cells are never changed."
  (let* ((view ein:nbview--view)
         (cell (and view (ein:nbview--cell-at (point))))
         (b (and cell (ein:nbview--source-bounds view cell))))
    (if (not (and b
                  (<= (car b) (line-beginning-position))
                  (<= (line-end-position) (cdr b))))
        'noindent
      (let ((offset (- (point) (car b)))
            (text (buffer-substring-no-properties (car b) (cdr b)))
            column tabs width)
        (ein:nbview--in-shadow (ein:nbview--cell-mode cell) text
          (goto-char (1+ offset))
          (indent-according-to-mode)
          (setq column (current-indentation)
                tabs indent-tabs-mode
                width tab-width))
        (let ((in-indentation (<= (current-column) (current-indentation))))
          (save-excursion
            (let ((indent-tabs-mode tabs)
                  (tab-width width))
              (indent-line-to column)))
          (when in-indentation
            (back-to-indentation)))))))

(defun ein:nbview-newline (&optional arg)
  "Insert a newline (ARG times) and indent the new line for its cell."
  (interactive "*P")
  (newline arg)
  (ein:nbview-indent-line))

(defun ein:nbview-indent-or-complete (&optional arg)
  "Indent the line for its cell language, or complete.
Like `indent-for-tab-command' (ARG is passed to it): `tab-always-indent'
decides when TAB completes through `completion-at-point'."
  (interactive "P")
  (indent-for-tab-command arg))

;;; Command and edit states
;;
;; In command state (the default) printable keys are notebook commands
;; and never insert text; in edit state the selected cell's source is
;; edited normally.  The state keymaps are installed through buffer-local
;; `minor-mode-overriding-map-alist' entries, so no global binding
;; changes.  Selecting another cell while editing keeps edit state, as in
;; VS Code: the leave hook runs for the old cell and the enter hook for
;; the new one.  Moving point within a cell runs no hook.

(defcustom ein:nbview-modal t
  "Non-nil: the cells view has a command state and an edit state.
Nil: no command state; the buffer behaves like ordinary editing and
only the `C-c' bindings of `ein:nbview-mode-map' are added.  Takes
effect for notebooks opened afterwards."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-escape-key nil
  "Additional key that leaves edit state, as a `key-valid-p' string.
Useful in terminals, where ESC is the Meta prefix; `ESC ESC' also
leaves edit state.  Takes effect for notebooks opened afterwards."
  :type '(choice (const :tag "None" nil) (key :tag "Key"))
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-mouse t
  "Non-nil: `mouse-1' selects cells and enters edit state."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defvar ein:nbview-enter-edit-hook nil
  "Normal hook run after a cell enters edit state.
It runs in the notebook buffer with point in the cell's source; the
cell is `ein:nbview--selected'.  Errors are logged, not signalled.")

(defvar ein:nbview-leave-edit-hook nil
  "Normal hook run after a cell leaves edit state.
It runs in the notebook buffer while `ein:nbview--selected' is still
the cell being left.  Errors are logged, not signalled.")

(defvar-local ein:nbview--state nil
  "State of the cells view: `command' or `edit'.")

(defvar-local ein:nbview--selected nil
  "The selected cell, as seen by the edit hooks.")

(defvar-local ein:nbview--command-active nil
  "Non-nil when `ein:nbview-command-map' is active.")

(defvar-local ein:nbview--edit-active nil
  "Non-nil when the edit-state keymap is active.")

(defvar ein:nbview--editing)
(declare-function ein:nbview-set-editing "ein-nbview")
(declare-function ein:nbview--current-view "ein-nbview")
(declare-function ein:nbview--cell-or-error "ein-nbview")
(declare-function ein:nbview--goto-source "ein-nbview")
(declare-function ein:nbview-select-cell "ein-nbview")
(declare-function ein:nbview-run-cell "ein-nbview")
(declare-function ein:nbview-insert-cell-below "ein-nbview")
(declare-function ein:view-cells "ein-view")
(declare-function ein:view-select-cell "ein-view")
(declare-function ein:nbview-next-cell "ein-nbview")
(declare-function ein:nbview-previous-cell "ein-nbview")
(declare-function ein:nbview-insert-cell-above "ein-nbview")
(declare-function ein:nbview-delete-cell "ein-nbview")
(declare-function ein:nbview-to-markdown "ein-nbview")
(declare-function ein:nbview-to-code "ein-nbview")
(declare-function ein:nbview-undo "ein-nbview")
(declare-function ein:nbview-move-cell-up "ein-nbview")
(declare-function ein:nbview-move-cell-down "ein-nbview")

(defvar ein:nbview-command-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (keymap-set map "RET" #'ein:nbview-edit-cell)
    (keymap-set map "<return>" #'ein:nbview-edit-cell)
    (keymap-set map "<escape>" #'ein:nbview-command-state)
    (keymap-set map "j" #'ein:nbview-next-cell)
    (keymap-set map "<down>" #'ein:nbview-next-cell)
    (keymap-set map "k" #'ein:nbview-previous-cell)
    (keymap-set map "<up>" #'ein:nbview-previous-cell)
    (keymap-set map "a" #'ein:nbview-insert-cell-above)
    (keymap-set map "b" #'ein:nbview-insert-cell-below)
    (keymap-set map "d d" #'ein:nbview-delete-cell)
    (keymap-set map "m" #'ein:nbview-to-markdown)
    (keymap-set map "y" #'ein:nbview-to-code)
    (keymap-set map "S-RET" #'ein:nbview-run-and-advance)
    (keymap-set map "S-<return>" #'ein:nbview-run-and-advance)
    (keymap-set map "C-RET" #'ein:nbview-run-cell)
    (keymap-set map "C-<return>" #'ein:nbview-run-cell)
    (keymap-set map "z" #'ein:nbview-undo)
    (keymap-set map "M-<up>" #'ein:nbview-move-cell-up)
    (keymap-set map "M-<down>" #'ein:nbview-move-cell-down)
    (keymap-set map "?" #'ein:nbview-help)
    map)
  "Keymap of the command state of the cells view.
Built with `suppress-keymap': printable keys without a binding here do
nothing.  Bindings made by the user are kept when EIN is reloaded.")

(defvar ein:nbview-edit-map
  (let ((map (make-sparse-keymap)))
    (keymap-set map "<escape>" #'ein:nbview-command-state)
    (keymap-set map "ESC ESC" #'ein:nbview-command-state)
    (keymap-set map "S-RET" #'ein:nbview-run-and-advance)
    (keymap-set map "S-<return>" #'ein:nbview-run-and-advance)
    (keymap-set map "C-RET" #'ein:nbview-run-cell)
    (keymap-set map "C-<return>" #'ein:nbview-run-cell)
    (keymap-set map "TAB" #'ein:nbview-indent-or-complete)
    (keymap-set map "RET" #'ein:nbview-newline)
    map)
  "Keymap of the edit state of the cells view.
Keys not bound here keep their usual editing meaning.")

(defvar-local ein:nbview--edit-local-map nil
  "The edit-state keymap of this buffer.
`ein:nbview-edit-map', or a child of it binding `ein:nbview-escape-key'.")

(defun ein:nbview--run-edit-hook (hook)
  "Run HOOK, logging and skipping functions that signal."
  (run-hook-wrapped
   hook
   (lambda (fn)
     (condition-case err
         (funcall fn)
       (error (ein:log 'warn "%s: %S failed: %s" hook fn (error-message-string err))))
     nil)))

(defun ein:nbview--apply-state ()
  "Make keymaps, cursor and decorations match `ein:nbview--state'."
  (let ((edit (eq ein:nbview--state 'edit)))
    (setq ein:nbview--command-active (and ein:nbview-modal (not edit))
          ein:nbview--edit-active (and ein:nbview-modal edit))
    (if ein:nbview-modal
        (setq-local cursor-type (if edit 'box 'hollow))
      (kill-local-variable 'cursor-type))
    (unless (eq (and edit t) (and ein:nbview--editing t))
      (ein:nbview-set-editing edit))))

(defun ein:nbview-modes-setup ()
  "Install the command and edit states in the current cells-view buffer."
  (setq ein:nbview--edit-local-map
        (if (and ein:nbview-escape-key (key-valid-p ein:nbview-escape-key))
            (let ((map (make-sparse-keymap)))
              (set-keymap-parent map ein:nbview-edit-map)
              (keymap-set map ein:nbview-escape-key #'ein:nbview-command-state)
              map)
          ein:nbview-edit-map))
  (setq-local minor-mode-overriding-map-alist
              (append `((ein:nbview--command-active . ,ein:nbview-command-map)
                        (ein:nbview--edit-active . ,ein:nbview--edit-local-map))
                      (cl-remove-if (lambda (e) (memq (car e) '(ein:nbview--command-active
                                                                ein:nbview--edit-active)))
                                    minor-mode-overriding-map-alist)))
  (setq ein:nbview--state (if ein:nbview-modal 'command 'edit))
  (ein:nbview--apply-state))

(defun ein:nbview--selection-changed (old new)
  "Run the edit hooks when the selection moves from OLD to NEW while editing.
Called by `ein:view-select-cell' before `ein:nbview--selected' becomes NEW."
  (if (and (eq ein:nbview--state 'edit) (not (eq old new)))
      (progn
        (when old (ein:nbview--run-edit-hook 'ein:nbview-leave-edit-hook))
        (setq ein:nbview--selected new)
        (when new (ein:nbview--run-edit-hook 'ein:nbview-enter-edit-hook)))
    (setq ein:nbview--selected new)))

(defun ein:nbview-edit-cell ()
  "Edit the selected cell: enter edit state with point in its source."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error))
         (bounds (ein:nbview--source-bounds view cell)))
    (unless (and bounds (<= (car bounds) (point) (cdr bounds)))
      (ein:nbview--goto-source view cell))
    (unless (eq ein:nbview--state 'edit)
      (setq ein:nbview--state 'edit)
      (setq ein:nbview--selected cell)
      (ein:nbview--apply-state)
      (ein:nbview--run-edit-hook 'ein:nbview-enter-edit-hook))))

(defun ein:nbview-command-state ()
  "Leave edit state for command state.
Does nothing in command state or when `ein:nbview-modal' is nil."
  (interactive)
  (when (and ein:nbview-modal (eq ein:nbview--state 'edit))
    (ein:nbview--run-edit-hook 'ein:nbview-leave-edit-hook)
    (setq ein:nbview--state 'command)
    (ein:nbview--apply-state)))

(defun ein:nbview-run-and-advance ()
  "Run the current code cell (or leave a Markdown cell), then go to the next.
At the last cell, a new code cell is added below and edited."
  (interactive)
  (let* ((view (ein:nbview--current-view))
         (cell (ein:nbview--cell-or-error))
         (cells (ein:view-cells view))
         (next (cadr (memq cell cells))))
    (if (ein:codecell-p cell)
        (ein:nbview-run-cell)
      (ein:nbview-command-state))
    (if next
        (ein:nbview-select-cell next)
      (ein:nbview-insert-cell-below "code")
      (ein:nbview-edit-cell))))

(defun ein:nbview-help ()
  "Show the bindings of the current state."
  (interactive)
  (describe-keymap (if (eq ein:nbview--state 'edit)
                       (or ein:nbview--edit-local-map ein:nbview-edit-map)
                     ein:nbview-command-map)))

;;; Mouse

(defun ein:nbview-mouse-select (event)
  "Select the cell clicked by EVENT.
A click in a source places point there and enters edit state; a click
on a header, footer or output selects the cell in command state.  With
`ein:nbview-mouse' nil, only point moves."
  (interactive "e")
  (if-let* ((url (ein:nbview--event-url event)))
      (browse-url url)
  (if (not ein:nbview-mouse)
      (mouse-set-point event)
    (let* ((posn (event-start event))
           (window (posn-window posn))
           (pos (posn-point posn)))
      (when (windowp window)
        (select-window window)
        (set-buffer (window-buffer window)))
      (when-let* ((view ein:nbview--view)
                  ((integer-or-marker-p pos))
                  (cell (ein:nbview--cell-at pos))
                  (bounds (ein:nbview--source-bounds view cell)))
        (let ((part (get-text-property pos 'ein-nbview-part)))
          (if (or (eq part 'header)
                  (and (eq part 'footer) (posn-string posn))
                  (not (<= (car bounds) pos (cdr bounds))))
              (progn
                (ein:nbview-command-state)
                (ein:nbview--goto-source view cell))
            (goto-char pos)
            (ein:view-select-cell view cell)
            (ein:nbview-edit-cell))))))))

(defun ein:nbview--event-url (event)
  "The `ein-url' of the link (in a preview or output) clicked by EVENT."
  (let* ((posn (event-start event))
         (str (posn-string posn)))
    (or (and (stringp (car-safe str)) (cdr str)
             (< (cdr str) (length (car str)))
             (get-text-property (cdr str) 'ein-url (car str)))
        (and (integer-or-marker-p (posn-point posn))
             (windowp (posn-window posn))
             (with-current-buffer (window-buffer (posn-window posn))
               (get-char-property (posn-point posn) 'ein-url))))))

(provide 'ein-nbview-edit)

;;; ein-nbview-edit.el ends here
