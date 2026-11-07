;;; test-ein-nbview-toolbar.el --- Toolbars and kernel status -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-toolbar.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-toolbar.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-toolbar.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T150-T152: the header-line notebook toolbar, the selected-cell
;; toolbar and the kernel status display.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defmacro ein:testing-with-toolbar-nbview (&rest body)
  "Open smoke.ipynb in the cells view, shown in the selected window."
  (declare (indent 0) (debug t))
  `(let ((ein:notebook-view 'cells))
     (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun ein:testing-toolbar-buttons (s)
  "The buttons of S: a list of (LABEL COMMAND HELP POS).
A button is a run of S with an `ein-nbview-command' property."
  (let ((i 0) acc)
    (while (< i (length s))
      (let ((next (or (next-single-property-change i 'ein-nbview-command s)
                      (length s)))
            (cmd (get-text-property i 'ein-nbview-command s)))
        (when cmd
          (should (eq (lookup-key (get-text-property i 'keymap s)
                                  [header-line mouse-1])
                      'ein:nbview-toolbar-click))
          (should (eq (lookup-key (get-text-property i 'keymap s) [mouse-1])
                      'ein:nbview-toolbar-click))
          (push (list (substring-no-properties s i next) cmd
                      (get-text-property i 'help-echo s) i)
                acc))
        (setq i next)))
    (nreverse acc)))

(defun ein:testing-toolbar-click (s button &optional pos)
  "Click BUTTON of string S, shown at buffer position POS or the header line."
  (ein:nbview-toolbar-click
   (list 'mouse-1 (list (selected-window) (or pos 'header-line) '(0 . 0) 0
                        (cons s (nth 3 button))))))

(defun ein:testing-mode-line-string (construct)
  "CONSTRUCT, a mode line construct, as a string with its properties.
`format-mode-line' returns \"\" in batch Emacs, so this handles the
constructs the cells view uses: strings, symbols, (:eval FORM), lists."
  (cond ((null construct) "")
        ((stringp construct) construct)
        ((symbolp construct)
         (if (boundp construct)
             (ein:testing-mode-line-string (symbol-value construct))
           ""))
        ((eq (car-safe construct) :eval)
         (ein:testing-mode-line-string (eval (cadr construct) t)))
        ((consp construct)
         (mapconcat #'ein:testing-mode-line-string construct ""))
        (t "")))

(defun ein:testing-toolbar-header-line ()
  "The current buffer's header line, as a string."
  (ein:testing-mode-line-string header-line-format))

(defun ein:testing-toolbar-header-displays ()
  "The header display strings of all cells, in order."
  (let ((view ein:nbview--view))
    (mapcar (lambda (c)
              (get-text-property (ein:nbview--header-pos view c) 'display))
            (ein:view-cells view))))

(defun ein:testing-toolbar-count (command strings)
  "How many of STRINGS have a button for COMMAND."
  (cl-count-if (lambda (s)
                 (cl-some (lambda (b) (eq (nth 1 b) command))
                          (ein:testing-toolbar-buttons s)))
               strings))

;; T150
(ert-deftest ein:nbview-toolbar-header-line ()
  (ein:testing-with-toolbar-nbview
    (let* ((s (ein:testing-toolbar-header-line))
           (buttons (ein:testing-toolbar-buttons s))
           (commands (mapcar #'cadr buttons)))
      (should (stringp s))
      (dolist (cmd '(ein:nbview-run-all ein:nbview-restart-kernel
                     ein:nbview-interrupt-kernel ein:nbview-add-code-cell
                     ein:nbview-add-markdown-cell ein:notebook-save-notebook-command
                     ein:nbview-select-kernel))
        (should (memq cmd commands)))
      ;; The commands also have keys (contracts/commands-and-keymaps.md).
      (should (eq (keymap-lookup ein:nbview-mode-map "C-c C-f") #'ein:nbview-run-all))
      (should (eq (keymap-lookup ein:nbview-mode-map "C-c C-x C-k")
                  #'ein:nbview-select-kernel))
      ;; Every button has a tooltip.
      (dolist (b buttons) (should (nth 2 b)))
      ;; The kernel name and status are shown.
      (should (string-match-p "python" s))
      ;; Non-graphic: ASCII labels.
      (should-not (string-match-p "[^[:ascii:]]" s))
      ;; Each button runs its command.
      (dolist (b buttons)
        (let (called)
          (cl-letf (((symbol-function (nth 1 b))
                     (lambda (&rest _) (interactive) (setq called t))))
            (ein:testing-toolbar-click s b))
          (should called))))))

(ert-deftest ein:nbview-toolbar-graphic-labels ()
  (ein:testing-with-toolbar-nbview
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (should (string-match-p "[^[:ascii:]]" (ein:testing-toolbar-header-line))))))

(ert-deftest ein:nbview-toolbar-off ()
  (let ((ein:nbview-toolbar nil))
    (ein:testing-with-toolbar-nbview
      (should-not (ein:testing-toolbar-buttons
                   (or (ein:testing-toolbar-header-line) ""))))))

;; T151
(ert-deftest ein:nbview-toolbar-cell-toolbar-follows-selection ()
  (ein:testing-with-toolbar-nbview
    (let* ((view ein:nbview--view)
           (cells (ein:view-cells view)))
      (should (>= (length cells) 2))
      (ein:nbview-select-cell (car cells))
      (let ((displays (ein:testing-toolbar-header-displays)))
        (should (= 1 (ein:testing-toolbar-count 'ein:nbview-run-cell displays)))
        (should (ein:testing-toolbar-count 'ein:nbview-run-cell (list (car displays)))))
      (ein:nbview-select-cell (nth 1 cells))
      (run-hooks 'post-command-hook)
      (let ((displays (ein:testing-toolbar-header-displays)))
        (should (= 1 (ein:testing-toolbar-count 'ein:nbview-run-cell displays)))
        (should (= 1 (ein:testing-toolbar-count 'ein:nbview-run-cell (list (nth 1 displays))))))
      ;; The buttons cover the contract's actions, each with a tooltip.
      (let* ((shown (nth 1 (ein:testing-toolbar-header-displays)))
             (buttons (ein:testing-toolbar-buttons shown))
             (commands (mapcar #'cadr buttons)))
        (should (equal commands '(ein:nbview-run-cell ein:nbview-insert-cell-below
                                  ein:nbview-delete-cell ein:nbview-move-cell-up
                                  ein:nbview-move-cell-down ein:nbview-more-actions)))
        (dolist (b buttons) (should (nth 2 b)))
        ;; A click acts on the clicked cell, even when another one is
        ;; selected by then (e.g. a hovered cell's toolbar).
        (ein:nbview-select-cell (car cells))
        (let (acted-on)
          (cl-letf (((symbol-function 'ein:nbview-run-cell)
                     (lambda () (interactive)
                       (setq acted-on (ein:nbview--cell-at (point))))))
            ;; A click on the second cell's Run button.
            (ein:testing-toolbar-click shown (car buttons)
                                       (ein:nbview--header-pos view (nth 1 cells))))
          (should (eq acted-on (nth 1 cells)))))
      (should (ein:nbview--check-invariants)))))

(ert-deftest ein:nbview-toolbar-more-actions ()
  (ein:testing-with-toolbar-nbview
    (let* ((cell (car (ein:view-cells ein:nbview--view)))
           offered called)
      (ein:nbview-select-cell cell)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq offered (all-completions "" collection))
                   (car (cl-remove-if-not (lambda (s) (string-match-p "type" s))
                                          offered))))
                ((symbol-function 'ein:nbview-toggle-cell-type)
                 (lambda () (interactive) (setq called t))))
        (call-interactively #'ein:nbview-more-actions))
      (should called)
      (dolist (re '("type" "Split" "Merge" "Clear output" "input" "output"
                    "Copy source" "Copy output" "View output"
                    "Copy cell" "Cut cell" "Paste cell" "traceback"))
        (should (cl-some (lambda (s) (string-match-p re s)) offered))))))

(ert-deftest ein:nbview-toolbar-cell-toolbar-off ()
  (let ((ein:nbview-cell-toolbar nil))
    (ein:testing-with-toolbar-nbview
      (should (= 0 (ein:testing-toolbar-count
                    'ein:nbview-run-cell (ein:testing-toolbar-header-displays)))))))

;; T152
(ert-deftest ein:nbview-toolbar-kernel-status ()
  (ein:testing-with-toolbar-nbview
    (let* ((notebook ein:%notebook%)
           (kernel (ein:$notebook-kernel notebook))
           (events (ein:$notebook-events notebook))
           (counts 0)
           (count (lambda (&rest _) (cl-incf counts))))
      (dolist (fn '(ein:nbview--render-cell ein:nbview--render-header
                    ein:nbview--render-footer ein:nbview--decorate-cell))
        (advice-add fn :before count))
      (unwind-protect
          (dolist (status '(busy idle disconnected))
            (setf (ein:$kernel-status kernel) status)
            (ein:events-trigger events (intern (format "status_%s.Kernel" status)))
            (should (string-match-p (symbol-name status)
                                    (ein:testing-mode-line-string mode-line-process)))
            (should (string-match-p (symbol-name status)
                                    (ein:testing-toolbar-header-line))))
        (dolist (fn '(ein:nbview--render-cell ein:nbview--render-header
                      ein:nbview--render-footer ein:nbview--decorate-cell))
          (advice-remove fn count)))
      (should (= 0 counts)))))

(provide 'test-ein-nbview-toolbar)
;;; test-ein-nbview-toolbar.el ends here
