;;; test-ein-nbview-modal.el --- Command/edit states of the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-modal.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-modal.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-modal.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T117-T121: command and edit states, their keymaps, the opt-out,
;; the global map, mouse selection and the extra escape key.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defmacro ein:testing-with-modal-nbview (&rest body)
  "Open smoke.ipynb in the cells view, shown in the selected window."
  (declare (indent 0) (debug t))
  `(let ((ein:notebook-view 'cells))
     (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun ein:testing-modal-keys (keys)
  "Run KEYS (a `kbd' string) as typed in the current buffer."
  (execute-kbd-macro (kbd keys)))

(defun ein:testing-modal-cells ()
  (ein:view-cells ein:nbview--view))

(defun ein:testing-modal-text (cell)
  (ein:view-cell-text ein:nbview--view cell))

;; T117
(ert-deftest ein:nbview-modal-states ()
  (ein:testing-with-modal-nbview
    ;; (a)
    (should (eq ein:nbview--state 'command))
    (should (eq cursor-type 'hollow))
    ;; (b)
    (should (memq (key-binding "q") '(undefined ignore)))
    (should (memq (key-binding "x") '(undefined ignore)))
    (let ((tick (buffer-modified-tick)))
      (ein:testing-modal-keys "q")
      (ein:testing-modal-keys "x")
      (should (= tick (buffer-modified-tick))))
    ;; (c)
    (let ((cell (ein:nbview--cell-at (point))))
      (ein:testing-modal-keys "RET")
      (should (eq ein:nbview--state 'edit))
      (should (eq cursor-type 'box))
      (should ein:nbview--editing)
      (should (eq cell (ein:nbview--cell-at (point))))
      ;; (d)
      (let ((before (ein:testing-modal-text cell)))
        (ein:testing-modal-keys "abc")
        (should (equal (concat "abc" before) (ein:testing-modal-text cell))))
      ;; (e)
      (ein:testing-modal-keys "<escape>")
      (should (eq ein:nbview--state 'command))
      (should-not ein:nbview--editing))
    ;; (f)
    (let* ((cells (ein:testing-modal-cells))
           (first (car cells)))
      (ein:nbview-select-cell first)
      (ein:testing-modal-keys "j")
      (should (eq (nth 1 cells) (oref ein:nbview--view selected)))
      (ein:testing-modal-keys "k")
      (should (eq first (oref ein:nbview--view selected)))
      (should (eq ein:nbview--state 'command)))
    ;; (g)
    (pcase-dolist (`(,key . ,cmd)
                   '(("a" . ein:nbview-insert-cell-above)
                     ("b" . ein:nbview-insert-cell-below)
                     ("d d" . ein:nbview-delete-cell)
                     ("m" . ein:nbview-to-markdown)
                     ("y" . ein:nbview-to-code)
                     ("j" . ein:nbview-next-cell)
                     ("k" . ein:nbview-previous-cell)
                     ("<down>" . ein:nbview-next-cell)
                     ("<up>" . ein:nbview-previous-cell)
                     ("z" . ein:nbview-undo)
                     ("?" . ein:nbview-help)
                     ("S-<return>" . ein:nbview-run-and-advance)
                     ("C-<return>" . ein:nbview-run-cell)
                     ("M-<up>" . ein:nbview-move-cell-up)
                     ("M-<down>" . ein:nbview-move-cell-down)))
      (should (eq cmd (key-binding (kbd key)))))))

(ert-deftest ein:nbview-modal-command-keys-act ()
  "a/b stay in command state; d d deletes; m/y convert; undo restores."
  (ein:testing-with-modal-nbview
    (let ((n (length (ein:testing-modal-cells))))
      (ein:testing-modal-keys "b")
      (should (= (1+ n) (length (ein:testing-modal-cells))))
      (should (eq ein:nbview--state 'command))
      (ein:testing-modal-keys "m")
      (should (ein:markdowncell-p (ein:nbview--cell-at (point))))
      (ein:testing-modal-keys "y")
      (should (ein:codecell-p (ein:nbview--cell-at (point))))
      (ein:testing-modal-keys "d d")
      (should (= n (length (ein:testing-modal-cells))))
      (ein:testing-modal-keys "a")
      (should (= (1+ n) (length (ein:testing-modal-cells))))
      (should (ein:nbview--check-invariants)))))

(ert-deftest ein:nbview-modal-edit-switch-runs-hooks ()
  "Selecting another cell while editing leaves the old cell and enters
the new one; motion within a cell runs no hook."
  (ein:testing-with-modal-nbview
    (let* ((cells (ein:testing-modal-cells))
           log)
      (add-hook 'ein:nbview-enter-edit-hook
                (lambda () (push (cons 'enter ein:nbview--selected) log)) nil t)
      (add-hook 'ein:nbview-leave-edit-hook
                (lambda () (push (cons 'leave ein:nbview--selected) log)) nil t)
      (add-hook 'ein:nbview-enter-edit-hook (lambda () (error "Broken hook")) nil t)
      (ein:nbview-select-cell (car cells))
      (ein:testing-modal-keys "RET")
      (should (equal log (list (cons 'enter (car cells)))))
      (setq log nil)
      (ein:testing-modal-keys "C-e")
      (should-not log)
      (ein:testing-modal-keys "C-c C-n")
      (should (eq ein:nbview--state 'edit))
      (should (equal (reverse log) (list (cons 'leave (car cells))
                                         (cons 'enter (nth 1 cells)))))
      (setq log nil)
      (ein:testing-modal-keys "<escape>")
      (should (equal log (list (cons 'leave (nth 1 cells))))))))

(ert-deftest ein:nbview-modal-run-and-advance ()
  (ein:testing-with-modal-nbview
    (let* ((cells (ein:testing-modal-cells))
           (last (car (last cells)))
           ran)
      (cl-letf (((symbol-function 'ein:kernel-when-ready)
                 (lambda (_k cb) (push t ran) (ignore cb))))
        ;; Markdown: leaves edit, no run, next cell selected.
        (ein:nbview-select-cell (car cells))
        (ein:testing-modal-keys "RET")
        (ein:testing-modal-keys "S-<return>")
        (should (eq ein:nbview--state 'command))
        (should (eq (nth 1 cells) (oref ein:nbview--view selected)))
        ;; Last code cell: runs, then a new code cell in edit state.
        (ein:nbview-select-cell last)
        (ein:testing-modal-keys "S-<return>")
        (should ran)
        (let ((new (oref ein:nbview--view selected)))
          (should-not (memq new cells))
          (should (ein:codecell-p new))
          (should (eq new (car (last (ein:testing-modal-cells)))))
          (should (eq ein:nbview--state 'edit)))
        ;; C-RET in edit runs in place and leaves edit.
        (setq ran nil)
        (ein:nbview-select-cell last)
        (ein:nbview-edit-cell)
        (ein:testing-modal-keys "C-<return>")
        (should ran)
        (should (eq last (oref ein:nbview--view selected)))
        (should (eq ein:nbview--state 'command))))))

;; T118
(ert-deftest ein:nbview-modal-off ()
  (let ((ein:nbview-modal nil))
    (ein:testing-with-modal-nbview
      (should (eq ein:nbview--state 'edit))
      (should-not ein:nbview--command-active)
      (let ((cell (ein:nbview--cell-at (point)))
            (n (length (ein:testing-modal-cells))))
        (ein:testing-modal-keys "jxq")
        (should (string-prefix-p "jxq" (ein:testing-modal-text cell)))
        (ein:nbview-command-state)
        (should (eq ein:nbview--state 'edit))
        (ein:testing-modal-keys "C-c C-b")
        (should (= (1+ n) (length (ein:testing-modal-cells))))
        (should (eq 'ein:nbview-run-cell (key-binding (kbd "C-c C-c"))))))))

;; T119
(ert-deftest ein:nbview-modal-global-map-untouched ()
  (let* ((keys (mapcar #'kbd '("RET" "j" "<escape>" "C-<return>" "S-<return>"
                               "M-RET" "<mouse-1>")))
         (snapshot (lambda () (mapcar (lambda (k) (lookup-key (current-global-map) k))
                                      keys)))
         (before (funcall snapshot)))
    (load "ein-nbview-edit" nil t)
    (ein:testing-with-modal-nbview
      (ein:testing-modal-keys "RET")
      (should (equal before (funcall snapshot))))
    (should (equal before (funcall snapshot)))))

;; T120
(defun ein:testing-modal-click (pos &optional on-string)
  "A mouse-1 event at POS; ON-STRING: as on a header or footer display."
  (let ((posn (or (and (not on-string) (posn-at-point pos))
                  (list (selected-window) pos '(0 . 0) 0
                        (and on-string (cons "x" 0)) pos))))
    (list 'mouse-1 posn)))

(ert-deftest ein:nbview-modal-mouse ()
  (ein:testing-with-modal-nbview
    (let* ((view ein:nbview--view)
           (cells (ein:testing-modal-cells))
           (md (car cells))
           (code (nth 1 cells))
           (cb (ein:nbview--source-bounds view code))
           (entered 0))
      (should (ein:markdowncell-p md))
      (should (ein:codecell-p code))
      (ein:nbview-select-cell md)
      ;; Click inside the code source.
      (let ((pos (min (cdr cb) (+ 2 (car cb)))))
        (ein:nbview-mouse-select (ein:testing-modal-click pos))
        (should (eq code (oref view selected)))
        (should (= pos (point)))
        (should (eq ein:nbview--state 'edit)))
      ;; Click on the header of the markdown cell: command state.
      (ein:nbview-mouse-select
       (ein:testing-modal-click (ein:nbview--header-pos view md) t))
      (should (eq md (oref view selected)))
      (should (eq ein:nbview--state 'command))
      (should (= (point) (car (ein:nbview--source-bounds view md))))
      ;; Click on the markdown source: edit and the hook runs.
      (add-hook 'ein:nbview-enter-edit-hook (lambda () (cl-incf entered)) nil t)
      (let ((mb (ein:nbview--source-bounds view md)))
        (ein:nbview-mouse-select (ein:testing-modal-click (1+ (car mb)))))
      (should (eq ein:nbview--state 'edit))
      (should (= 1 entered))
      ;; Disabled: only point moves.
      (ein:nbview-command-state)
      (let ((ein:nbview-mouse nil))
        (ein:nbview-mouse-select (ein:testing-modal-click (+ 1 (car cb))))
        (should (= (point) (+ 1 (car cb))))
        (should (eq ein:nbview--state 'command))))))

;; T121
(ert-deftest ein:nbview-modal-escape-key ()
  (let ((ein:nbview-escape-key "C-c C-q"))
    (ein:testing-with-modal-nbview
      (ein:nbview-edit-cell)
      (should (eq 'ein:nbview-command-state (key-binding (kbd "C-c C-q"))))
      (ein:testing-modal-keys "C-c C-q")
      (should (eq ein:nbview--state 'command))
      (ein:nbview-edit-cell)
      (should (eq 'ein:nbview-command-state (key-binding (kbd "ESC ESC"))))
      (ein:testing-modal-keys "ESC ESC")
      (should (eq ein:nbview--state 'command))
      ;; ESC as Meta still works in edit state.
      (ein:nbview-edit-cell)
      (should (eq 'execute-extended-command (key-binding (kbd "ESC x")))))))

(defun ein:testing-modal-my-cmd ()
  (interactive))

(ert-deftest ein:nbview-modal-user-bindings-survive ()
  (keymap-set ein:nbview-command-map "x" #'ein:testing-modal-my-cmd)
  (keymap-set ein:nbview-mode-map "C-c C-c" #'ein:testing-modal-my-cmd)
  (unwind-protect
      (progn
        (load "ein-nbview-edit" nil t)
        (load "ein-nbview" nil t)
        (ein:testing-with-modal-nbview
          (should (eq 'ein:testing-modal-my-cmd (key-binding "x")))
          (should (eq 'ein:testing-modal-my-cmd (key-binding (kbd "C-c C-c"))))))
    (keymap-unset ein:nbview-command-map "x" t)
    (keymap-set ein:nbview-mode-map "C-c C-c" #'ein:nbview-run-cell)))

(provide 'test-ein-nbview-modal)
;;; test-ein-nbview-modal.el ends here
