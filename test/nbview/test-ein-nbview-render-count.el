;;; test-ein-nbview-render-count.el --- Cells view renders incrementally -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-render-count.el is free software: you can redistribute
;; it and/or modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-render-count.el is distributed in the hope that it
;; will be useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See
;; the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-render-count.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T082 (SC-008): on the 300-cell benchmark notebook, typing,
;; selection and output arrival re-render only the affected cells.
;; Counts calls, not time, so the result does not depend on the host.

;;; Code:

(require 'ert)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)

(defvar ein:testing-render-count--counts nil
  "Alist of (FUNCTION . CALLS).")

(defun ein:testing-render-count--counter (fn)
  "Advice counting calls of FN."
  (lambda (orig &rest args)
    (cl-incf (alist-get fn ein:testing-render-count--counts 0))
    (apply orig args)))

(defmacro ein:testing-with-render-counts (fns &rest body)
  "Run BODY counting calls to each function of FNS."
  (declare (indent 1) (debug t))
  (let ((advices (make-symbol "advices")))
    `(let ((ein:testing-render-count--counts nil)
           (,advices (mapcar (lambda (fn) (cons fn (ein:testing-render-count--counter fn)))
                             ,fns)))
       (unwind-protect
           (progn
             (dolist (a ,advices) (advice-add (car a) :around (cdr a)))
             ,@body)
         (dolist (a ,advices) (advice-remove (car a) (cdr a)))))))

(defun ein:testing-render-count (fn)
  (alist-get fn ein:testing-render-count--counts 0))

(defun ein:testing-render-count-reset ()
  (setq ein:testing-render-count--counts nil))

(defun ein:testing-bench-notebook ()
  "Generate the 300-cell benchmark notebook; return its path or skip."
  (let ((python (executable-find "python3"))
        (script (expand-file-name
                 "../bench/make-bench-nb.py"
                 (file-name-directory (locate-library "test-ein-nbview-render-count")))))
    (unless python (ert-skip "python3 not found"))
    (let ((file (make-temp-file "ein-bench-" nil ".ipynb")))
      (unless (zerop (call-process python nil nil nil "-I" script file))
        (delete-file file)
        (error "make-bench-nb.py failed"))
      file)))

(ert-deftest ein:nbview-render-count-300-cells ()
  (let ((file (ein:testing-bench-notebook))
        (ein:notebook-view 'cells))
    (unwind-protect
        (ein:testing-with-render-counts '(ein:nbview--render-cell
                                          ein:nbview--render-header
                                          ein:nbview--render-footer
                                          ein:nbview--decorate-cell)
          (ein:testing-with-notebook-file file
            (let* ((view ein:nbview--view)
                   (cells (ein:view-cells view)))
              ;; Initial render: each cell once.
              (should (= 300 (length cells)))
              (should (= 300 (ein:testing-render-count 'ein:nbview--render-cell)))
              (should (ein:nbview--check-invariants))
              ;; Typing 10 characters re-renders at most one cell.
              (ein:nbview-select-cell (nth 150 cells))
              (ein:testing-render-count-reset)
              (dotimes (_ 10)
                (insert "a")
                (run-hooks 'post-command-hook))
              (should (<= (+ (ein:testing-render-count 'ein:nbview--render-cell)
                             (ein:testing-render-count 'ein:nbview--render-header)
                             (ein:testing-render-count 'ein:nbview--render-footer))
                          1))
              (should (<= (ein:testing-render-count 'ein:nbview--decorate-cell) 1))
              ;; Moving the selection 150 -> 151 decorates exactly two cells.
              (ein:testing-render-count-reset)
              (goto-char (car (ein:nbview--source-bounds view (nth 151 cells))))
              (run-hooks 'post-command-hook)
              (should (eq (nth 151 cells) (oref view selected)))
              (should (= 2 (ein:testing-render-count 'ein:nbview--decorate-cell)))
              (should (= 0 (ein:testing-render-count 'ein:nbview--render-cell)))
              ;; An output arriving for cell 10 re-renders one footer.
              (ein:testing-render-count-reset)
              (let ((cell (cl-find-if #'ein:codecell-p (nthcdr 10 cells))))
                (ein:cell-append-output cell (list :output_type "stream"
                                                   :name "stdout" :text "x\n"))
                (should (= 1 (ein:testing-render-count 'ein:nbview--render-footer)))
                (should (= 0 (ein:testing-render-count 'ein:nbview--render-cell)))
                (should (string-match-p
                         "x\n" (get-text-property
                                (ein:nbview--footer-pos
                                 (ein:nbview--header-pos view cell))
                                'display)))))))
      (delete-file file))))

(provide 'test-ein-nbview-render-count)
;;; test-ein-nbview-render-count.el ends here
