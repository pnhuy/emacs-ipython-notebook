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

(provide 'ein-nbview-edit)

;;; ein-nbview-edit.el ends here
