;;; test-ein-nbview-copy-yank.el --- Cell copy, yank and traceback -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-copy-yank.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-copy-yank.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-copy-yank.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; The cells view's C-c C-w (copy cell), C-c C-y (yank cell) and
;; C-c C-$ (traceback) of contracts/commands-and-keymaps.md.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-kill-ring)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defmacro ein:testing-with-copy-nbview (&rest body)
  "Open smoke.ipynb in the cells view and run BODY with a fresh kill ring."
  (declare (indent 0) (debug t))
  `(let ((ein:notebook-view 'cells)
         (ein:kill-ring nil)
         (ein:kill-ring-yank-pointer nil))
     (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
       (let ((last-command nil) (this-command nil))
         ,@body))))

(defun ein:testing-copy-command (fn &rest args)
  "Run FN with ARGS the way the command loop runs a command."
  (undo-boundary)
  (setq this-command fn)
  (prog1 (apply fn args)
    (setq last-command this-command)
    (ein:nbview--post-command)))

(ert-deftest ein:nbview-copy-yank-cell ()
  (ein:testing-with-copy-nbview
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view)))
           (n (length (ein:view-cells view))))
      (should (slot-value code 'outputs))
      (ein:nbview-select-cell code)
      (ein:testing-copy-command #'ein:nbview-copy-cell)
      ;; Copying leaves the notebook alone.
      (should (= n (length (ein:view-cells view))))
      (ein:nbview-select-cell (car (ein:view-cells view)))
      (ein:testing-copy-command #'ein:nbview-yank-cell)
      (let* ((cells (ein:view-cells view))
             (new (nth 1 cells)))
        (should (= (1+ n) (length cells)))
        (should-not (eq new code))
        (should (eq code (nth 2 cells)))
        (should (equal "code" (slot-value new 'cell-type)))
        (should (equal (ein:view-cell-text view code) (ein:view-cell-text view new)))
        (should (equal (slot-value code 'outputs) (slot-value new 'outputs)))
        (should (equal (slot-value code 'metadata) (slot-value new 'metadata)))
        (should-not (equal (slot-value code 'cell-id) (slot-value new 'cell-id)))
        (should (eq new (ein:nbview--cell-at (point))))
        (should (ein:nbview--check-invariants))
        ;; A second yank gets yet another id.
        (ein:testing-copy-command #'ein:nbview-yank-cell)
        (let ((ids (mapcar (lambda (c) (slot-value c 'cell-id))
                           (ein:view-cells view))))
          (should (= (length ids) (length (delete-dups (copy-sequence ids))))))
        ;; One undo per yank.
        (ein:testing-copy-command #'ein:nbview-undo)
        (ein:testing-copy-command #'ein:nbview-undo)
        (should (= n (length (ein:view-cells view))))
        (should (ein:nbview--check-invariants))))))

(ert-deftest ein:nbview-copy-snapshots-source ()
  (ein:testing-with-copy-nbview
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view))))
      (ein:nbview-select-cell code)
      (let ((text (ein:view-cell-text view code)))
        (ein:testing-copy-command #'ein:nbview-copy-cell)
        ;; Edit after copying: the copy keeps the old source.
        (ein:nbview--goto-source view code t)
        (insert "\n# later")
        (ein:testing-copy-command #'ein:nbview-yank-cell)
        (should (equal text (ein:view-cell-text view (ein:nbview--cell-at (point)))))))))

(ert-deftest ein:nbview-cut-yank-cell ()
  (ein:testing-with-copy-nbview
    (let* ((view ein:nbview--view)
           (cells (ein:view-cells view))
           (code (cadr cells)))
      (ein:nbview-select-cell code)
      (ein:testing-copy-command #'ein:nbview-cut-cell)
      (should (equal (list (car cells)) (ein:view-cells view)))
      (ein:nbview-select-cell (car cells))
      (ein:testing-copy-command #'ein:nbview-yank-cell)
      (let ((new (cadr (ein:view-cells view))))
        (should (equal "code" (slot-value new 'cell-type)))
        (should (equal (slot-value code 'outputs) (slot-value new 'outputs))))
      (should (ein:nbview--check-invariants)))))

(ert-deftest ein:nbview-yank-empty-kill-ring ()
  (ein:testing-with-copy-nbview
    (should-error (ein:nbview-yank-cell) :type 'user-error)))

(ert-deftest ein:nbview-copy-yank-keys ()
  (should (eq (keymap-lookup ein:nbview-mode-map "C-c C-w") #'ein:nbview-copy-cell))
  (should (eq (keymap-lookup ein:nbview-mode-map "C-c C-y") #'ein:nbview-yank-cell))
  (should (eq (keymap-lookup ein:nbview-mode-map "C-c C-$") #'ein:nbview-show-traceback)))

(ert-deftest ein:nbview-show-traceback ()
  (ein:testing-with-copy-nbview
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view))))
      (ein:nbview-select-cell code)
      ;; A stream output only: no traceback.
      (should-error (ein:nbview-show-traceback) :type 'user-error)
      (ein:cell-append-output
       code (list :output_type "error" :ename "ZeroDivisionError"
                  :evalue "division by zero"
                  :traceback '("Traceback (most recent call last)" "ZeroDivisionError: division by zero")))
      (ein:nbview--cancel-output-timers)
      (ein:nbview-select-cell code)
      (let ((shown nil))
        (cl-letf (((symbol-function 'display-buffer)
                   (lambda (b &rest _) (setq shown b) nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (b &rest _) (setq shown b) nil)))
          (ein:nbview-show-traceback))
        (should shown)
        (with-current-buffer shown
          (should (string-match-p "ZeroDivisionError" (buffer-string))))))))

(provide 'test-ein-nbview-copy-yank)
;;; test-ein-nbview-copy-yank.el ends here
