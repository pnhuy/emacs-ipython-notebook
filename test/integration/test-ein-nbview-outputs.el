;;; test-ein-nbview-outputs.el --- Rich outputs on a live kernel -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-outputs.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-outputs.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-outputs.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T142: run cells producing a matplotlib figure, an HTML table, LaTeX,
;; a traceback and a long stream in the cells view; check what the
;; footers show, then save, reopen and check the outputs are still
;; shown (SC-007).  Batch Emacs has no graphic frame, so images show as
;; their placeholder there.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-testing-server)
(require 'ein-testing-nbformat)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'test-ein-smoke)

(defun ein:testing-outputs-run (view cell source)
  "Set CELL's SOURCE in VIEW, run it and wait until it is done."
  (ein:view-set-cell-text view cell source)
  (ein:nbview-select-cell cell)
  (ein:nbview-run-cell)
  (should (ein:testing-wait-until (lambda () (oref cell running)) 10))
  (should (ein:testing-wait-until (lambda () (not (oref cell running))) 60))
  ;; Let the coalescing timer render the last outputs.
  (accept-process-output nil 0.2)
  (or (ein:nbview--footer-rendered view cell) ""))

(defun ein:testing-outputs-image-p (string)
  "Non-nil when STRING shows an image, its placeholder or, in a
terminal (which prefers text), the figure's text representation."
  (or (string-match-p "\\[image/png\\|<Figure size" string)
      (let ((pos 0) found)
        (while (and (not found) (< pos (length string)))
          (when (eq (car-safe (get-text-property pos 'display string)) 'image)
            (setq found t))
          (setq pos (or (next-single-property-change pos 'display string)
                        (length string))))
        found)))

(ert-deftest ein:integration-nbview-rich-outputs ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          (ein:notebook-view 'cells)
          (ein:nbview-output-max-lines 200)
          (file (expand-file-name "outputs.ipynb" ein:testing-server-dir))
          notebook shown)
      (copy-file (ein:testing-fixture "smoke.ipynb") file)
      (unwind-protect
          (progn
            (setq notebook (ein:testing-login-and-open
                            (directory-file-name url) token "outputs.ipynb"))
            (should (ein:testing-wait-until
                     (lambda () (ein:kernel-live-p (ein:$notebook-kernel notebook)))
                     30))
            (with-current-buffer (ein:notebook-buffer notebook)
              (let* ((view ein:nbview--view)
                     (first (nth 1 (ein:view-cells view)))
                     (cells (list first)))
                (ein:nbview-select-cell first)
                (dotimes (_ 4)
                  (setq cells (append cells (list (ein:nbview-insert-cell-below "code")))))
                (should (ein:testing-outputs-image-p
                         (ein:testing-outputs-run
                          view (nth 0 cells)
                          "import matplotlib\nmatplotlib.use('module://matplotlib_inline.backend_inline')\nimport matplotlib.pyplot as plt\nplt.plot([1, 2]); plt.show()")))
                (should (string-match-p
                         "42" (ein:testing-outputs-run
                               view (nth 1 cells)
                               "from IPython.display import HTML\nHTML('<table><tr><td>42</td></tr></table>')")))
                (let ((s (ein:testing-outputs-run
                          view (nth 2 cells)
                          "from IPython.display import Math\nMath(r'\\alpha')")))
                  (should (string-match-p "alpha\\|α\\|\\[" s)))
                (setq shown (ein:testing-outputs-run view (nth 3 cells) "1/0"))
                (should (string-match-p "ZeroDivisionError" shown))
                (let ((s (ein:testing-outputs-run view (nth 4 cells) "print('x\\n' * 5000)")))
                  (should (string-match-p "more lines" s))
                  (should (< (cl-count ?\n s) 300))))
              (let (saved)
                (ein:notebook-save-notebook notebook (lambda (&rest _) (setq saved t)))
                (should (ein:testing-wait-until (lambda () saved) 20))))
            (ein:testing-kill-notebook notebook)
            (ein:testing-nbformat-validate file)
            ;; Reopen: the saved outputs show again, nothing runs.
            (setq notebook (ein:testing-login-and-open
                            (directory-file-name url) token "outputs.ipynb"))
            (with-current-buffer (ein:notebook-buffer notebook)
              (let* ((view ein:nbview--view)
                     (cells (cdr (ein:view-cells view))))
                (should (ein:testing-outputs-image-p
                         (ein:nbview--footer-rendered view (nth 0 cells))))
                (should (string-match-p
                         "ZeroDivisionError"
                         (ein:nbview--footer-rendered view (nth 3 cells))))
                (should-not (cl-some (lambda (c) (ein:oref-safe c 'running)) cells)))))
        (when notebook (ein:testing-kill-notebook notebook))))))

(provide 'test-ein-nbview-outputs)
;;; test-ein-nbview-outputs.el ends here
