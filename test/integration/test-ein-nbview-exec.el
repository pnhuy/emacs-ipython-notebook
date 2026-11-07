;;; test-ein-nbview-exec.el --- Execute in the cells view (live) -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-exec.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-exec.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-exec.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T083: against a real Jupyter Server, open smoke.ipynb in the cells
;; view, run its code cell with `ein:nbview-run-cell', see the prompt
;; and stream output appear, save, and check the saved source equals
;; the buffer text.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-testing-server)
(require 'ein-testing-nbformat)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'test-ein-smoke)

(ert-deftest ein:integration-nbview-run-cell ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          (ein:notebook-view 'cells)
          (file (expand-file-name "smoke.ipynb" ein:testing-server-dir))
          notebook buffer-source)
      (copy-file (ein:testing-fixture "smoke.ipynb") file)
      (unwind-protect
          (progn
            (setq notebook (ein:testing-login-and-open
                            (directory-file-name url) token "smoke.ipynb"))
            (should (ein:testing-wait-until
                     (lambda () (ein:kernel-live-p (ein:$notebook-kernel notebook)))
                     30))
            (with-current-buffer (ein:notebook-buffer notebook)
              (should (eq major-mode 'ein:nbview-mode))
              (let* ((view ein:nbview--view)
                     (cell (nth 1 (ein:view-cells view))))
                (should (ein:codecell-p cell))
                (ein:nbview-select-cell cell)
                (ein:nbview-run-cell)
                (should (ein:testing-wait-until
                         (lambda () (and (not (oref cell running))
                                         (numberp (oref cell input-prompt-number))))
                         60))
                (let ((h (ein:nbview--header-pos view cell)))
                  (should (string-match-p "\\[1\\]" (get-text-property h 'display)))
                  (should (ein:testing-wait-until
                           (lambda ()
                             (string-match-p
                              "/" (get-text-property (ein:nbview--footer-pos
                                                      (ein:nbview--header-pos view cell))
                                                     'display)))
                           20)))
                (should (ein:nbview--check-invariants))
                (setq buffer-source (ein:view-cell-text view cell))))
            (let (saved)
              (ein:notebook-save-notebook notebook (lambda (&rest _) (setq saved t)))
              (should (ein:testing-wait-until (lambda () saved) 20))))
        (ein:testing-kill-notebook notebook))
      (ein:testing-nbformat-validate file)
      (let* ((saved (json-parse-string
                     (with-temp-buffer (insert-file-contents file) (buffer-string))
                     :object-type 'alist :array-type 'list))
             (code (nth 1 (alist-get 'cells saved)))
             (src (alist-get 'source code)))
        (should (equal buffer-source (if (stringp src) src (apply #'concat src))))
        (should (equal 1 (alist-get 'execution_count code)))
        (should (cl-some (lambda (o) (equal "stream" (alist-get 'output_type o)))
                         (alist-get 'outputs code)))))))

(provide 'test-ein-nbview-exec)
;;; test-ein-nbview-exec.el ends here
