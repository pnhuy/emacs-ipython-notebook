;;; test-ein-nbview-undo.el --- Cells view undo and redo -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-undo.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-undo.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-undo.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T093 (SC-008): property test -- random text and structural edits,
;; then undo step by step back to the opened notebook and redo to the
;; end, comparing the serialization at every step.
;; T094: focused undo scenarios (cell identity, outputs, placeholder,
;; read-only boundaries, undo past the open point).

;;; Code:

(require 'ert)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defmacro ein:testing-undo-with-nbview (fixture &rest body)
  "Open round-trip FIXTURE in the cells view and run BODY in its buffer."
  (declare (indent 1) (debug t))
  `(let ((ein:notebook-view 'cells))
     (ein:testing-with-notebook-file (ein:testing-fixture ,fixture)
       (let ((last-command nil) (this-command nil))
         ,@body))))

(defun ein:testing-undo-json ()
  "The current notebook serialized."
  (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))

(defun ein:testing-undo-command (fn &rest args)
  "Run FN with ARGS the way the command loop runs a command."
  (undo-boundary)
  (setq this-command fn)
  (prog1 (apply fn args)
    (setq last-command this-command)
    (ein:nbview--post-command)))

(defun ein:testing-undo-cell-ids ()
  (mapcar (lambda (c) (slot-value c 'cell-id)) (ein:view-cells ein:nbview--view)))

;;; T093 property test

(defconst ein:testing-undo-ops
  '(insert-text delete-text insert-above insert-below delete-cell
    move-up move-down convert split merge)
  "Operation classes of the property test.")

(defun ein:testing-undo-random-source-pos (view cell)
  "A random position in CELL's source; move point there."
  (let* ((b (ein:nbview--source-bounds view cell))
         (pos (+ (car b) (random (1+ (- (cdr b) (car b)))))))
    (goto-char pos)
    (ein:view-select-cell view cell)
    pos))

(defun ein:testing-undo-random-op (view)
  "Apply one random valid operation; return its name or nil if none applied."
  (let* ((cells (ein:view-cells view))
         (op (nth (random (length ein:testing-undo-ops)) ein:testing-undo-ops))
         (cell (and cells (nth (random (length cells)) cells)))
         (i (and cell (cl-position cell cells))))
    (if (null cell)
        (progn (ein:testing-undo-command #'ein:nbview-insert-cell-below) 'insert-below)
      (ein:testing-undo-random-source-pos view cell)
      (pcase op
        ('insert-text
         (ein:testing-undo-command
          #'insert (nth (random 4) '("x" "foo = 1" "\n" "# a\nb = 2\n")))
         op)
        ('delete-text
         (let* ((b (ein:nbview--source-bounds view cell))
                (len (- (cdr b) (point))))
           (when (> len 0)
             (ein:testing-undo-command #'delete-region (point)
                                       (+ (point) 1 (random len)))
             op)))
        ('insert-above (ein:testing-undo-command #'ein:nbview-insert-cell-above) op)
        ('insert-below
         (ein:testing-undo-command #'ein:nbview-insert-cell-below
                                   (if (zerop (random 2)) "code" "markdown"))
         op)
        ('delete-cell (ein:testing-undo-command #'ein:nbview-delete-cell) op)
        ('move-up (when (> i 0) (ein:testing-undo-command #'ein:nbview-move-cell-up) op))
        ('move-down (when (< i (1- (length cells)))
                      (ein:testing-undo-command #'ein:nbview-move-cell-down) op))
        ('convert (ein:testing-undo-command
                   (if (ein:codecell-p cell) #'ein:nbview-to-markdown #'ein:nbview-to-code))
                  op)
        ('split (ein:testing-undo-command #'ein:nbview-split-cell) op)
        ('merge (when (< i (1- (length cells)))
                  (ein:testing-undo-command #'ein:nbview-merge-cell) op))))))

(defun ein:testing-undo-property (seed nops)
  "Run the T093 property test with SEED and NOPS operations."
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (random seed)
    (let* ((view ein:nbview--view)
           (snapshots (list (ein:testing-undo-json)))
           (applied nil))
      (should-not (buffer-modified-p))
      ;; Five extra cells: part of the setup, not of the history.
      (dotimes (_ 5) (ein:testing-undo-command #'ein:nbview-insert-cell-below)
               (ein:testing-undo-command #'insert "y = 0"))
      (setq snapshots (list (ein:testing-undo-json)))
      (while (< (length applied) nops)
        (when-let* ((op (ein:testing-undo-random-op view)))
          (push op applied)
          (should (ein:nbview--check-invariants))
          (push (ein:testing-undo-json) snapshots)))
      ;; snapshots: newest first; (nth k snapshots) is the state after
      ;; NOPS - k operations.
      (let ((final (car snapshots)))
        (cl-loop for k from 1 to nops
                 for expect = (nth k snapshots)
                 do (ein:testing-undo-command #'ein:nbview-undo)
                 (should (ein:nbview--check-invariants))
                 (unless (equal expect (ein:testing-undo-json))
                   (ert-fail (list :seed seed :undo-step k
                                   :undoing (nth (1- k) applied))))
                 (should (equal expect (ein:testing-undo-json))))
        (cl-loop for k from 1 to nops
                 do (ein:testing-undo-command #'ein:nbview-undo-redo)
                 (should (ein:nbview--check-invariants))
                 (unless (equal (nth (- nops k) snapshots) (ein:testing-undo-json))
                   (ert-fail (list :seed seed :redo-step k
                                   :redoing (nth (- nops k) applied)))))
        (should (equal final (ein:testing-undo-json)))))))

(ert-deftest ein:nbview-undo-property ()
  "Every undo step restores the exact prior serialization (3 seeds x 60 ops)."
  (dolist (seed '("ein-undo-seed-1" "ein-undo-seed-2" "ein-undo-seed-3"))
    (ein:testing-undo-property seed 60)))

;;; T094 focused tests

(defun ein:testing-undo-add-output (cell text)
  (setf (slot-value cell 'outputs)
        (append (slot-value cell 'outputs)
                (list (list :output_type "stream" :name "stdout" :text text))))
  (ein:view-cell-outputs-changed (slot-value cell 'view) cell))

;; (a)
(ert-deftest ein:nbview-undo-delete-restores-cell ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view)))
           (id (slot-value code 'cell-id))
           (meta (copy-tree (slot-value code 'metadata)))
           (outputs (slot-value code 'outputs))
           (before (ein:testing-undo-json)))
      (should outputs)
      (ein:nbview-select-cell code)
      (ein:testing-undo-command #'ein:nbview-delete-cell)
      (should-not (memq code (ein:view-cells view)))
      (ein:testing-undo-command #'ein:nbview-undo)
      (should (eq code (cadr (ein:view-cells view))))
      (should (equal id (slot-value code 'cell-id)))
      (should (equal meta (slot-value code 'metadata)))
      (should (eq outputs (slot-value code 'outputs)))
      (should (equal before (ein:testing-undo-json)))
      (should (ein:nbview--check-invariants)))))

;; (b)
(ert-deftest ein:nbview-undo-move ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (ids (ein:testing-undo-cell-ids)))
      (ein:nbview-select-cell (car (ein:view-cells view)))
      (ein:testing-undo-command #'ein:nbview-move-cell-down)
      (should (equal (reverse ids) (ein:testing-undo-cell-ids)))
      (ein:testing-undo-command #'ein:nbview-undo)
      (should (equal ids (ein:testing-undo-cell-ids)))
      (should (ein:nbview--check-invariants)))))

;; (c)
(ert-deftest ein:nbview-undo-convert ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view)))
           (id (slot-value code 'cell-id))
           (outputs (slot-value code 'outputs)))
      (ein:nbview-select-cell code)
      (ein:testing-undo-command #'ein:nbview-to-markdown)
      (should (ein:markdowncell-p (cadr (ein:view-cells view))))
      (ein:testing-undo-command #'ein:nbview-undo)
      (let ((back (cadr (ein:view-cells view))))
        (should (eq code back))
        (should (ein:codecell-p back))
        (should (equal id (slot-value back 'cell-id)))
        (should (eq outputs (slot-value back 'outputs))))
      (should (eq code (oref view selected)))
      (should (ein:nbview--check-invariants)))))

;; (d)
(ert-deftest ein:nbview-undo-output-between-edits ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view)))
           (s0 (ein:view-cell-text view code)))
      (ein:nbview--goto-source view code t)
      (ein:testing-undo-command #'insert "A")
      (ein:nbview--assert-no-undo-entries
       (lambda () (ein:testing-undo-add-output code "late\n")))
      (ein:testing-undo-command #'insert "B")
      (should (equal (concat s0 "AB") (ein:view-cell-text view code)))
      (ein:testing-undo-command #'ein:nbview-undo)
      (should (equal (concat s0 "A") (ein:view-cell-text view code)))
      (ein:testing-undo-command #'ein:nbview-undo)
      (should (equal s0 (ein:view-cell-text view code)))
      (should (string-match-p "late" (get-text-property
                                      (ein:nbview--footer-pos
                                       (ein:nbview--header-pos view code))
                                      'display)))
      (should (ein:nbview--check-invariants)))))

;; (e)
(ert-deftest ein:nbview-undo-kill-across-cells ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cells (ein:view-cells view))
           (beg (car (ein:nbview--source-bounds view (car cells))))
           (end (cdr (ein:nbview--source-bounds view (cadr cells))))
           (text (buffer-string))
           (kill-ring nil))
      (should-error (kill-region beg end) :type 'text-read-only)
      (should (equal text (buffer-string)))
      (should-not (buffer-modified-p))
      (should (ein:nbview--check-invariants)))))

;; (f)
(ert-deftest ein:nbview-undo-output-for-deleted-cell ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view))))
      (ein:nbview-select-cell code)
      (ein:testing-undo-command #'ein:nbview-delete-cell)
      (ein:testing-undo-add-output code "while deleted\n")
      (should (= 2 (length (slot-value code 'outputs))))
      (ein:testing-undo-command #'ein:nbview-undo)
      (should (eq code (cadr (ein:view-cells view))))
      (should (string-match-p "while deleted"
                              (get-text-property
                               (ein:nbview--footer-pos
                                (ein:nbview--header-pos view code))
                               'display)))
      (should (string-match-p "while deleted" (ein:testing-undo-json))))))

;; (g)
(ert-deftest ein:nbview-undo-delete-last-cell ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cells (ein:view-cells view)))
      (ein:nbview-select-cell (car cells))
      (ein:testing-undo-command #'ein:nbview-delete-cell)
      (ein:testing-undo-command #'ein:nbview-delete-cell)
      (should-not (ein:view-cells view))
      (should (text-property-any (point-min) (point-max)
                                 'ein-nbview-part 'placeholder))
      (should (equal nil (alist-get 'cells (json-parse-string
                                            (ein:testing-undo-json)
                                            :object-type 'alist
                                            :array-type 'list))))
      (ein:testing-undo-command #'ein:nbview-undo)
      (should (equal (list (cadr cells)) (ein:view-cells view)))
      (should-not (text-property-any (point-min) (point-max)
                                     'ein-nbview-part 'placeholder))
      (should (eq (cadr cells) (oref view selected)))
      (should (ein:nbview--check-invariants)))))

;; (h)
(ert-deftest ein:nbview-undo-past-open-point ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let ((opened (ein:testing-undo-json))
          (view ein:nbview--view))
      (ein:nbview-select-cell (car (ein:view-cells view)))
      (ein:testing-undo-command #'insert "hello")
      (ein:testing-undo-command #'ein:nbview-insert-cell-below)
      (ein:testing-undo-command #'insert "z = 3")
      (ein:testing-undo-command #'ein:nbview-move-cell-up)
      (ein:testing-undo-command #'ein:nbview-to-markdown)
      (should (buffer-modified-p))
      (let ((n 0))
        (should
         (equal "No further undo information"
                (cadr (should-error
                       (while (< (cl-incf n) 100)
                         (ein:testing-undo-command #'ein:nbview-undo))
                       :type 'user-error)))))
      (should (equal opened (ein:testing-undo-json)))
      (should-not (buffer-modified-p))
      (should (ein:nbview--check-invariants)))))

;; Split and merge (T098)
(ert-deftest ein:nbview-undo-split-merge ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view)))
           (id (slot-value code 'cell-id))
           (before (ein:testing-undo-json)))
      (ein:view-set-cell-text view code "a = 1\n\nb = 2")
      (setq before (ein:testing-undo-json))
      (ein:nbview--goto-source view code)
      (search-forward "\n")
      (ein:testing-undo-command #'ein:nbview-split-cell)
      (let* ((cells (ein:view-cells view))
             (new (nth 2 cells)))
        (should (= 3 (length cells)))
        (should (eq code (nth 1 cells)))
        (should (equal "a = 1" (ein:view-cell-text view code)))
        (should (equal "b = 2" (ein:view-cell-text view new)))
        (should (equal id (slot-value code 'cell-id)))
        (should-not (equal id (slot-value new 'cell-id)))
        (should-not (slot-value new 'outputs))
        (should (eq new (oref view selected)))
        (should (ein:nbview--check-invariants))
        ;; Merge it back into the cell above.
        (let ((current-prefix-arg '(4)))
          (ein:testing-undo-command #'ein:nbview-merge-cell t))
        (should (equal (list (car cells) code) (ein:view-cells view)))
        (should (equal "a = 1\nb = 2" (ein:view-cell-text view code)))
        (should (equal id (slot-value code 'cell-id)))
        (should (ein:nbview--check-invariants))
        (ein:testing-undo-command #'ein:nbview-undo)
        (should (equal (list (car cells) code new) (ein:view-cells view)))
        (ein:testing-undo-command #'ein:nbview-undo)
        (should (equal before (ein:testing-undo-json)))
        (should (ein:nbview--check-invariants))))))

(ert-deftest ein:nbview-undo-display-updates-leave-no-entries ()
  (ein:testing-undo-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view))))
      (ein:nbview--assert-no-undo-entries
       (lambda ()
         (setf (slot-value code 'input-prompt-number) 3)
         (ein:view-cell-status-changed view code)
         (ein:testing-undo-add-output code "x\n")
         (ein:nbview-select-cell (car (ein:view-cells view)))
         (ein:nbview-set-editing t)))
      (should-error (ein:nbview--assert-no-undo-entries
                     (lambda () (goto-char (car (ein:nbview--source-bounds view code)))
                       (insert "q")))))))

(provide 'test-ein-nbview-undo)
;;; test-ein-nbview-undo.el ends here
