;;; ein-nbview-toolbar.el --- Toolbars and kernel status of the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-nbview-toolbar.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; ein-nbview-toolbar.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-nbview-toolbar.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The compact notebook toolbar in the header line, the toolbar of the
;; selected (or hovered) cell, and the kernel status in the header and
;; mode lines.  Every button runs an ordinary command, so everything
;; stays available from the keyboard and M-x; in a terminal the labels
;; fall back to ASCII.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'eieio)
(require 'ein-core)
(require 'ein-classes)
(require 'ein-events)
(require 'ein-view)

(declare-function ein:nbview--current-view "ein-nbview")
(declare-function ein:nbview--cell-or-error "ein-nbview")
(declare-function ein:nbview--code-cell-or-error "ein-nbview")
(declare-function ein:nbview--goto-source "ein-nbview")
(declare-function ein:nbview--set-dirty "ein-nbview")
(declare-function ein:nbview--render-header "ein-nbview")
(declare-function ein:nbview-command-state "ein-nbview-edit")
(declare-function ein:nbview-insert-cell-below "ein-nbview")
(declare-function ein:nbview-run-cell "ein-nbview")
(declare-function ein:nbview-delete-cell "ein-nbview")
(declare-function ein:nbview-move-cell-up "ein-nbview")
(declare-function ein:nbview-move-cell-down "ein-nbview")
(declare-function ein:nbview-toggle-cell-type "ein-nbview")
(declare-function ein:nbview-split-cell "ein-nbview")
(declare-function ein:nbview-merge-cell "ein-nbview")
(declare-function ein:nbview-clear-output "ein-nbview")
(declare-function ein:nbview-toggle-input "ein-nbview")
(declare-function ein:nbview-toggle-output "ein-nbview")
(declare-function ein:nbview-toggle-output-truncation "ein-nbview")
(declare-function ein:nbview-output-copy "ein-nbview-output")
(declare-function ein:nbview-output-view "ein-nbview-output")
(declare-function ein:kernel-when-ready "ein-kernel")
(declare-function ein:kernel-delete-session "ein-kernel")
(declare-function ein:cell-execute "ein-cell")
(declare-function ein:get-notebook "ein-notebook")
(declare-function ein:list-available-kernels "ein-notebook")
(declare-function ein:notebook-switch-kernel "ein-notebook")
(declare-function ein:notebook-restart-session-command "ein-notebook")
(declare-function ein:notebook-kernel-interrupt-command "ein-notebook")
(declare-function ein:notebook-save-notebook-command "ein-notebook")

(defvar ein:%notification%)
(defvar ein:nbview--view)

;;; Options

(defcustom ein:nbview-toolbar t
  "Non-nil shows the notebook toolbar in the header line of the cells view.
The toolbar holds Run All, Restart, Interrupt, Add Code, Add Markdown,
Save and the kernel name and status.  Each button runs a command that
is also bound to a key and available with \\[execute-extended-command]."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-cell-toolbar t
  "Non-nil shows a small toolbar on the header of the selected cell.
Its buttons are Run, Add Cell, Delete, Move Up, Move Down and More
Actions.  Only the selected cell (and, see `ein:nbview-toolbar-on-hover',
the hovered one) shows it, to keep the notebook uncluttered."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-toolbar-on-hover t
  "Non-nil also shows the cell toolbar on a header under the mouse.
This works only in graphical frames, and only when
`ein:nbview-cell-toolbar' is non-nil."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defface ein:nbview-toolbar-button
  '((t :inherit (header-line)))
  "Face of the toolbar buttons."
  :group 'ein-nbview)

(defface ein:nbview-toolbar-status
  '((t :inherit (shadow)))
  "Face of the kernel name and status in the notebook toolbar."
  :group 'ein-nbview)

;;; Buttons

(defvar ein:nbview-toolbar-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'ein:nbview-toolbar-click)
    (define-key map [header-line mouse-1] #'ein:nbview-toolbar-click)
    map)
  "Keymap of a toolbar button.")

(defun ein:nbview--toolbar-graphic-p ()
  "Non-nil when toolbar labels may use non-ASCII symbols."
  (display-graphic-p))

(defun ein:nbview--toolbar-button (label ascii command help)
  "Return a button showing LABEL that runs COMMAND, with tooltip HELP.
In a terminal, or when LABEL's symbol cannot be displayed, show ASCII."
  (propertize (if (and (ein:nbview--toolbar-graphic-p)
                       (char-displayable-p (aref label 0)))
                  label
                ascii)
              'ein-nbview-command command
              'keymap ein:nbview-toolbar-map
              'mouse-face 'highlight
              'help-echo (if (string-search "\\[" help)
                             ;; Look the keys up only when shown.
                             (lambda (&rest _) (substitute-command-keys help))
                           help)
              'face 'ein:nbview-toolbar-button))

(defun ein:nbview-toolbar-click (event)
  "Run the command of the toolbar button clicked in EVENT.
A button on a cell header acts on that cell."
  (interactive "e")
  (let* ((posn (and (consp event) (event-start event)))
         (window (and posn (posn-window posn)))
         (obj (and posn (posn-string posn)))
         (string (car-safe obj))
         (idx (cdr-safe obj))
         (command (and (stringp string) idx
                       (get-text-property idx 'ein-nbview-command string)))
         (cell (and (stringp string) idx
                    (get-text-property idx 'ein-nbview-cell string))))
    (unless command
      (user-error "No toolbar button here"))
    (when (window-live-p window)
      (select-window window))
    (when (and cell ein:nbview--view)
      (ein:nbview--goto-source ein:nbview--view cell))
    (call-interactively command)))

;;; Notebook toolbar

(defun ein:nbview--kernel-status (notebook)
  "Return the status of NOTEBOOK's kernel as a string."
  (let ((kernel (and notebook (ein:$notebook-kernel notebook))))
    (if-let* ((status (and kernel (ein:$kernel-status kernel))))
        (format "%s" status)
      "not connected")))

(defun ein:nbview--kernel-name (notebook)
  "Return the display name of NOTEBOOK's kernelspec."
  (or (when-let* ((ks (and notebook (ein:$notebook-kernelspec notebook))))
        (ein:$kernelspec-name ks))
      (when-let* ((md (and notebook (ein:$notebook-metadata notebook)))
                  (ks (plist-get md :kernelspec)))
        (plist-get ks :name))
      "no kernel"))

(defun ein:nbview--notification-messages ()
  "The notebook and kernel messages of the classic notification widget."
  (when (bound-and-true-p ein:%notification%)
    (delq nil (list (ein:oref-safe (ein:oref-safe ein:%notification% 'notebook) 'message)
                    (ein:oref-safe (ein:oref-safe ein:%notification% 'kernel) 'message)))))

(defconst ein:nbview--toolbar-buttons
  '((ein:nbview-run-all "▶▶ Run All" "[Run All]" "▶▶" "[All]"
                        "Run all code cells (\\[ein:nbview-run-all])")
    (ein:nbview-restart-kernel "↻ Restart" "[Restart]" "↻" "[Rst]"
                               "Restart the kernel")
    (ein:nbview-interrupt-kernel "■ Interrupt" "[Interrupt]" "■" "[Int]"
                                 "Interrupt the kernel")
    (ein:nbview-add-code-cell "＋ Code" "[+Code]" "＋C" "[+C]"
                              "Add a code cell below the current cell")
    (ein:nbview-add-markdown-cell "＋ Markdown" "[+Markdown]" "＋M" "[+M]"
                                  "Add a Markdown cell below the current cell")
    (ein:notebook-save-notebook-command "💾 Save" "[Save]" "💾" "[S]"
                                        "Save the notebook"))
  "Notebook toolbar buttons:
\(COMMAND LABEL ASCII COMPACT-LABEL COMPACT-ASCII HELP).")

(defun ein:nbview--header-line-1 (notebook compact)
  "The notebook toolbar of NOTEBOOK; COMPACT non-nil uses short labels."
  (let ((kernel (ein:nbview--kernel-name notebook)))
    (concat
     " "
     (mapconcat
      (lambda (b)
        (pcase-let ((`(,cmd ,label ,ascii ,clabel ,cascii ,help) b))
          (ein:nbview--toolbar-button (if compact clabel label)
                                      (if compact cascii ascii)
                                      cmd help)))
      ein:nbview--toolbar-buttons " ")
     " "
     (ein:nbview--toolbar-button (format "⚙ %s" kernel) (format "[%s]" kernel)
                                 #'ein:nbview-select-kernel
                                 "Select the kernel (\\[ein:nbview-select-kernel])")
     " "
     (propertize (ein:nbview--kernel-status notebook) 'face 'ein:nbview-toolbar-status))))

(defun ein:nbview--header-line ()
  "Return the notebook toolbar for the current buffer's header line.
Labels get shorter when the full toolbar does not fit the window.
Notebook and kernel messages follow; they may be cut off."
  (let* ((notebook (bound-and-true-p ein:%notebook%))
         (full (ein:nbview--header-line-1 notebook nil))
         (window (get-buffer-window (current-buffer)))
         (width (if (window-live-p window) (window-total-width window) 80)))
    (concat (if (<= (string-width full) width)
                full
              (ein:nbview--header-line-1 notebook t))
            (mapconcat (lambda (m) (concat " | " m))
                       (ein:nbview--notification-messages) ""))))

;;; Cell toolbar

(defvar-local ein:nbview--hovered nil
  "The cell whose header is under the mouse, or nil.")

(defun ein:nbview--cell-toolbar-p (cell)
  "Non-nil when CELL's header shows the cell toolbar."
  (and ein:nbview-cell-toolbar
       (when-let* ((view (ein:oref-safe cell 'view)))
         (or (eq (ein:oref-safe view 'selected) cell)
             (and ein:nbview-toolbar-on-hover
                  (buffer-live-p (ein:oref-safe view 'buffer))
                  (eq (buffer-local-value 'ein:nbview--hovered (oref view buffer))
                      cell))))))

(defun ein:nbview--cell-toolbar ()
  "Return the cell toolbar string."
  (let ((g (and (ein:nbview--toolbar-graphic-p)
                (cl-every #'char-displayable-p '(?▶ ?＋ ?✕ ?↑ ?↓ ?⋯)))))
    (cl-flet ((b (label ascii cmd help)
                (propertize (if g label ascii)
                            'ein-nbview-command cmd
                            'keymap ein:nbview-toolbar-map
                            'mouse-face 'highlight
                            'help-echo help
                            'face 'ein:nbview-toolbar-button)))
      (concat (b "▶" "[Run]" #'ein:nbview-run-cell "Run this cell")
              " "
              (b "＋" "[+]" #'ein:nbview-insert-cell-below "Add a cell below")
              " "
              (b "✕" "[x]" #'ein:nbview-delete-cell "Delete this cell")
              " "
              (b "↑" "[^]" #'ein:nbview-move-cell-up "Move this cell up")
              " "
              (b "↓" "[v]" #'ein:nbview-move-cell-down "Move this cell down")
              " "
              (b "⋯" "[...]" #'ein:nbview-more-actions "More actions")))))

(defun ein:nbview--header-help (window _object pos)
  "`help-echo' function of cell headers: show the hovered cell's toolbar.
WINDOW and POS locate the mouse."
  (when (and ein:nbview-cell-toolbar ein:nbview-toolbar-on-hover
             (window-live-p window))
    (with-current-buffer (window-buffer window)
      (let ((cell (and pos (get-text-property pos 'ein-nbview-cell)))
            (old ein:nbview--hovered)
            (view ein:nbview--view))
        (when (and view (not (eq cell old)))
          (setq ein:nbview--hovered cell)
          (run-at-time 0 nil
                       (lambda ()
                         (when (buffer-live-p (oref view buffer))
                           (dolist (c (list old cell))
                             (when c (ein:nbview--render-header view c)))))))))
    nil))

;;; Commands

(defun ein:nbview--notebook ()
  "Return the current buffer's notebook or signal a `user-error'."
  (or (bound-and-true-p ein:%notebook%) (user-error "No notebook here")))

(defun ein:nbview-run-all ()
  "Execute all code cells, in order."
  (interactive)
  (let ((view (ein:nbview--current-view)))
    (ein:nbview-command-state)
    (dolist (cell (ein:view-cells view))
      (when (ein:codecell-p cell)
        (ein:view-cell-text view cell)
        (ein:kernel-when-ready
         (slot-value cell 'kernel)
         (lambda (_kernel)
           (ein:cell-execute cell)
           (ein:nbview--set-dirty view)))))))

(defun ein:nbview-restart-kernel ()
  "Restart the kernel (asks first)."
  (interactive)
  (call-interactively #'ein:notebook-restart-session-command))

(defun ein:nbview-interrupt-kernel ()
  "Interrupt the kernel."
  (interactive)
  (call-interactively #'ein:notebook-kernel-interrupt-command))

(defun ein:nbview-shutdown-kernel ()
  "Shut down the kernel.
Asks first when this Emacs did not start it or other sessions share it."
  (interactive)
  (ein:kernel-delete-session nil :kernel (ein:$notebook-kernel (ein:nbview--notebook))))

(defun ein:nbview-add-code-cell ()
  "Add a code cell below the current cell."
  (interactive)
  (ein:nbview-insert-cell-below "code"))

(defun ein:nbview-add-markdown-cell ()
  "Add a Markdown cell below the current cell."
  (interactive)
  (ein:nbview-insert-cell-below "markdown"))

(defun ein:nbview-select-kernel (kernel-name)
  "Switch the notebook to the kernel KERNEL-NAME."
  (interactive
   (let ((kernels (ein:list-available-kernels
                   (ein:$notebook-url-or-port (ein:nbview--notebook)))))
     (list (let ((choice (completing-read "Select kernel: " kernels nil t)))
             (or (car (rassoc choice kernels)) choice)))))
  (ein:notebook-switch-kernel (ein:nbview--notebook) kernel-name))

(defun ein:nbview-copy-source ()
  "Copy the current cell's source to the kill ring."
  (interactive)
  (let ((view (ein:nbview--current-view)))
    (kill-new (ein:view-cell-text view (ein:nbview--cell-or-error)))
    (message "Copied cell source")))

(defconst ein:nbview--more-actions
  '(("Change cell type (code/Markdown)" . ein:nbview-toggle-cell-type)
    ("Split cell at point" . ein:nbview-split-cell)
    ("Merge with the cell below" . ein:nbview-merge-cell)
    ("Clear output" . ein:nbview-clear-output)
    ("Collapse/expand input" . ein:nbview-toggle-input)
    ("Collapse/expand output" . ein:nbview-toggle-output)
    ("Expand/truncate long output" . ein:nbview-toggle-output-truncation)
    ("Copy source" . ein:nbview-copy-source)
    ("Copy output" . ein:nbview-output-copy)
    ("View output in a buffer" . ein:nbview-output-view))
  "Entries of `ein:nbview-more-actions': (LABEL . COMMAND).")

(defun ein:nbview-more-actions ()
  "Choose one of the less common actions on the current cell."
  (interactive)
  (ein:nbview--cell-or-error)
  (let* ((choice (completing-read "Cell action: " ein:nbview--more-actions nil t))
         (command (cdr (assoc choice ein:nbview--more-actions))))
    (when command
      (call-interactively command))))

;;; Kernel status

(defun ein:nbview--kernel-status-string (kernel)
  "Mode line string for KERNEL's status."
  (format " [%s]" (or (and kernel (ein:$kernel-status kernel)) "not connected")))

(cl-defmethod ein:view-kernel-status-changed ((view ein:view) kernel)
  "Show KERNEL's status in VIEW's mode and header lines; render nothing."
  (when-let* ((buffer (ein:oref-safe view 'buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq mode-line-process (ein:nbview--kernel-status-string kernel))
      (force-mode-line-update))))

(defconst ein:nbview--kernel-events
  '(status_busy.Kernel status_idle.Kernel status_dead.Kernel
    status_restarting.Kernel status_restarted.Kernel
    status_reconnecting.Kernel status_reconnected.Kernel
    status_disconnected.Kernel status_starting.Kernel)
  "Kernel events that change the status display.")

(defun ein:nbview-toolbar-setup (notebook view)
  "Set up the toolbar and kernel status of NOTEBOOK's cells VIEW.
Call in VIEW's buffer after the notification widget is set up."
  (when ein:nbview-toolbar
    (setq header-line-format '(:eval (ein:nbview--header-line))))
  (let ((kernel (ein:$notebook-kernel notebook)))
    (setq mode-line-process (ein:nbview--kernel-status-string kernel))
    (when-let* ((events (ein:$notebook-events notebook)))
      (dolist (type ein:nbview--kernel-events)
        (ein:events-on events type
                       (lambda (&rest _)
                         (ein:view-kernel-status-changed
                          view (ein:$notebook-kernel notebook))))))))

(provide 'ein-nbview-toolbar)

;;; ein-nbview-toolbar.el ends here
