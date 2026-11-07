;;; ein-nbview-bench.el --- Cells view benchmark (SC-009) -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-nbview-bench.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; ein-nbview-bench.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-nbview-bench.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A development benchmark, not part of the package (quickstart §7):
;;
;;   python3 -I test/bench/make-bench-nb.py /tmp/bench300.ipynb
;;   emacs -Q -L lisp -l test/bench/ein-nbview-bench.el \
;;     --eval '(ein:nbview-dev-benchmark "/tmp/bench300.ipynb")'
;;
;; The notebook is opened without a server (the kernel is a stub), so
;; nothing executes.  Every sample is `(benchmark-run 1 (progn ACTION
;; (redisplay t)))', so the time includes redisplay.  The report goes
;; to *ein-bench* and, in batch Emacs, to standard output.

;;; Code:

(eval-and-compile
  (let* ((here (file-name-directory (or load-file-name buffer-file-name)))
         (root (expand-file-name "../../" here))
         (deps (expand-file-name ".deps/elpa" root)))
    (when (file-directory-p deps)
      (setq package-user-dir deps)
      (package-initialize))
    (add-to-list 'load-path (expand-file-name "lisp" root))
    (add-to-list 'load-path (expand-file-name "test" root))))

(require 'cl-lib)
(require 'benchmark)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)

(defvar ein:nbview-bench--renders 0
  "Cell renders counted since the last reset.")

(defun ein:nbview-bench--count (&rest _)
  (cl-incf ein:nbview-bench--renders))

(defun ein:nbview-bench--time (action)
  "Seconds taken by ACTION followed by a forced redisplay."
  (car (benchmark-run 1 (progn (funcall action) (redisplay t)))))

(defun ein:nbview-bench--stats (samples)
  "The (MEDIAN P95) of SAMPLES, in milliseconds."
  (let* ((v (vconcat (sort (copy-sequence samples) #'<)))
         (n (length v))
         (at (lambda (q) (* 1000 (aref v (min (1- n) (floor (* q n))))))))
    (list (funcall at 0.5) (funcall at 0.95))))

(defun ein:nbview-bench--command (fn &rest args)
  "Run FN with ARGS as a command: the command hooks run around it."
  (lambda ()
    (let ((this-command fn))
      (run-hooks 'pre-command-hook)
      (apply fn args)
      (run-hooks 'post-command-hook))))

(defun ein:nbview-bench--repeat (n action)
  "Time ACTION N times; return the samples."
  (cl-loop repeat n collect (ein:nbview-bench--time action)))

(defun ein:nbview-dev-benchmark (file)
  "Benchmark the cells view on the notebook FILE and report.
Reports the open time, the median and p95 of each action in
milliseconds, and the cells re-rendered per typed character."
  (interactive "fNotebook: ")
  (let* ((ein:notebook-view 'cells)
         (buf nil)
         (open (car (benchmark-run 1
                      (setq buf (ein:testing-notebook-from-file file))
                      (switch-to-buffer buf)
                      (delete-other-windows)
                      (redisplay t))))
         (rows nil)
         (renders-per-edit nil)
         (typed nil)
         (output-shown nil))
    (with-current-buffer buf
      (let* ((view ein:nbview--view)
             (cells (ein:view-cells view))
             (code (cl-remove-if-not #'ein:codecell-p cells))
             (md (cl-remove-if #'ein:codecell-p cells))
             (mid (nth (/ (length code) 2) code))
             (render-fns '(ein:nbview--render-cell ein:nbview--render-header
                           ein:nbview--render-footer)))
        (cl-flet ((row (name samples) (push (cons name samples) rows)))
          ;; Typing: 20 characters in one code cell, in edit state.
          (ein:nbview-select-cell mid)
          (goto-char (cdr (ein:nbview--source-bounds view mid)))
          (funcall (ein:nbview-bench--command #'ein:nbview-edit-cell))
          (let ((before (ein:view-cell-text view mid)))
            (dolist (fn render-fns) (advice-add fn :before #'ein:nbview-bench--count))
          (setq ein:nbview-bench--renders 0)
          (row "type a character (x20)"
               (ein:nbview-bench--repeat
                20 (ein:nbview-bench--command #'self-insert-command 1 ?a)))
          (setq renders-per-edit (/ ein:nbview-bench--renders 20.0)
                typed (string-suffix-p (make-string 20 ?a)
                                       (ein:view-cell-text view mid))
                typed (and typed (not (string-suffix-p (make-string 20 ?a) before)))))
          (dolist (fn render-fns) (advice-remove fn #'ein:nbview-bench--count))
          (funcall (ein:nbview-bench--command #'ein:nbview-command-state))
          ;; Scrolling from the top.
          (goto-char (point-min))
          (row "scroll-up-command (x10)"
               (ein:nbview-bench--repeat
                10 (ein:nbview-bench--command #'scroll-up-command)))
          (row "scroll-down-command (x10)"
               (ein:nbview-bench--repeat
                10 (ein:nbview-bench--command #'scroll-down-command)))
          ;; Cell navigation in command state.
          (ein:nbview-select-cell (nth 100 cells))
          (row "j next cell (x20)"
               (ein:nbview-bench--repeat
                20 (ein:nbview-bench--command #'ein:nbview-next-cell)))
          (row "k previous cell (x20)"
               (ein:nbview-bench--repeat
                20 (ein:nbview-bench--command #'ein:nbview-previous-cell)))
          ;; Edit/command state toggles on a code cell.
          (ein:nbview-select-cell mid)
          (row "edit/command toggle (x10)"
               (cl-loop repeat 10
                        append (list (ein:nbview-bench--time
                                      (ein:nbview-bench--command #'ein:nbview-edit-cell))
                                     (ein:nbview-bench--time
                                      (ein:nbview-bench--command #'ein:nbview-command-state)))))
          ;; Markdown preview: entering a Markdown cell shows its
          ;; source, leaving it restores the preview.
          (let ((cell (nth (/ (length md) 2) md)))
            (ein:nbview-select-cell cell)
            (row "markdown source/preview toggle (x10)"
                 (cl-loop repeat 10
                          append (list (ein:nbview-bench--time
                                        (ein:nbview-bench--command #'ein:nbview-edit-cell))
                                       (ein:nbview-bench--time
                                        (ein:nbview-bench--command #'ein:nbview-command-state))))))
          ;; An output arriving for a visible code cell.
          (ein:nbview-select-cell mid)
          (row "output update (x10)"
               ;; Close the coalescing window before each sample, so
               ;; every sample is a full, immediate footer render.
               (cl-loop repeat 10
                        do (ein:nbview--cancel-output-timers)
                        collect
                        (ein:nbview-bench--time
                         (lambda ()
                           (ein:cell-append-output
                            mid (list :output_type "stream" :name "stdout" :text "x\n"))))))
          (ein:nbview--cancel-output-timers)
          (setq output-shown (string-match-p (apply #'concat (make-list 10 "x\n")) (or (ein:nbview--footer-rendered view mid) ""))))
        (let* ((invariants (ein:nbview--check-invariants))
               (report
               (with-temp-buffer
                 (insert (format "EIN cells view benchmark: %s\n" (abbreviate-file-name file)))
                 (insert (format "Emacs %s, %s, %d cells, window %dx%d\n"
                                 emacs-version
                                 (if (display-graphic-p) "graphic" "terminal")
                                 (length cells) (window-total-width) (window-total-height)))
                 (insert (format "open: %.0f ms\n" (* 1000 open)))
                 (insert (format "%-40s %10s %10s\n" "action" "median ms" "p95 ms"))
                 (dolist (r (reverse rows))
                   (pcase-let ((`(,median ,p95) (ein:nbview-bench--stats (cdr r))))
                     (insert (format "%-40s %10.1f %10.1f\n" (car r) median p95))))
                 (insert (format "cells re-rendered per edit: %.2f (typed text in the cell: %s)\n"
                                 renders-per-edit (if typed "yes" "NO")))
                 (insert (format "output shown after update: %s\n" (if output-shown "yes" "NO")))
                 (insert (format "invariants: %s\n"
                                 (if invariants "ok" "FAILED")))
                 (buffer-string))))
          (with-current-buffer (get-buffer-create "*ein-bench*")
            (erase-buffer)
            (insert report))
          (if noninteractive
              (princ report)
            (message "%s" report))
          report)))))

(provide 'ein-nbview-bench)
;;; ein-nbview-bench.el ends here
