;;; test-ein-nbview-edit.el --- Code editing in the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-edit.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-edit.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-edit.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T103-T106, T108: native font-lock, indentation, syntax and kernel
;; completion inside cells of the cells view, for Python and for
;; other kernel languages.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defmacro ein:testing-with-edit-nbview (&rest body)
  "Open smoke.ipynb in the cells view and run BODY in its buffer."
  (declare (indent 0) (debug t))
  `(let ((ein:notebook-view 'cells))
     (ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
       ,@body)))

(defun ein:testing-edit-cell (type text)
  "Insert a TYPE cell holding TEXT below the selected one; return it.
Point is left at the end of TEXT."
  (let ((cell (ein:nbview-insert-cell-below type)))
    (insert text)
    cell))

(defun ein:testing-edit-faces (pos)
  "The faces at POS, as a list."
  (ensure-list (get-text-property pos 'face)))

(defun ein:testing-edit-texts ()
  (mapcar (lambda (c) (ein:view-cell-text ein:nbview--view c))
          (ein:view-cells ein:nbview--view)))

(defun ein:testing-edit-notebook-json (language &optional extension)
  "A notebook for kernel LANGUAGE with one code cell."
  (json-encode
   `((cells . [((cell_type . "code") (execution_count . :null)
                (id . "c1") (metadata . ,(make-hash-table))
                (outputs . []) (source . "function f() {\nreturn 1;\n}"))])
     (metadata (kernelspec (display_name . ,language) (language . ,language)
                           (name . ,language))
               (language_info (name . ,language)
                              ,@(and extension `((file_extension . ,extension)))))
     (nbformat . 4) (nbformat_minor . 5))))

;; T103
(ert-deftest ein:nbview-edit-font-lock ()
  (ein:testing-with-edit-nbview
    (let* ((code (ein:testing-edit-cell "code" "def f():\n    return 1"))
           (md (ein:testing-edit-cell "markdown" "def is a word")))
      (font-lock-ensure)
      (let ((cpos (car (ein:nbview--source-bounds ein:nbview--view code)))
            (mpos (car (ein:nbview--source-bounds ein:nbview--view md))))
        (should (memq 'font-lock-keyword-face (ein:testing-edit-faces cpos)))
        (should (memq 'ein:nbview-code-face (ein:testing-edit-faces cpos)))
        (should-not (memq 'font-lock-keyword-face (ein:testing-edit-faces mpos)))
        ;; Editing refontifies: the keyword face goes with the keyword.
        (goto-char cpos)
        (delete-char 3)
        (insert "xyz")
        (font-lock-ensure)
        (should-not (memq 'font-lock-keyword-face (ein:testing-edit-faces cpos)))
        (should (ein:nbview--check-invariants))
        (should (string-prefix-p "xyz f" (ein:view-cell-text ein:nbview--view code)))))))

;; T104
(ert-deftest ein:nbview-edit-indentation ()
  (ein:testing-with-edit-nbview
    (let* ((before (ein:testing-edit-texts))
           (code (ein:testing-edit-cell "code" "def f():")))
      (newline-and-indent)
      (should (equal "def f():\n    " (ein:view-cell-text ein:nbview--view code)))
      (insert "x = 1")
      (newline)
      (insert "return 1")
      (let ((this-command 'indent-for-tab-command))
        (indent-for-tab-command))
      (should (equal "def f():\n    x = 1\n    return 1"
                     (ein:view-cell-text ein:nbview--view code)))
      ;; Mis-indented line is fixed.
      (back-to-indentation)
      (delete-horizontal-space)
      (insert "  ")
      (let ((this-command 'indent-for-tab-command))
        (indent-for-tab-command))
      (should (equal "def f():\n    x = 1\n    return 1"
                     (ein:view-cell-text ein:nbview--view code)))
      ;; The other cells are untouched.
      (should (equal before (remove (ein:view-cell-text ein:nbview--view code)
                                  (ein:testing-edit-texts))))
      (should (ein:nbview--check-invariants)))))

;; T104: RET indents.
(ert-deftest ein:nbview-edit-ret-indents ()
  (ein:testing-with-edit-nbview
    (let ((code (ein:testing-edit-cell "code" "if x:")))
      (should (eq (keymap-lookup ein:nbview-mode-map "RET") #'ein:nbview-newline))
      (ein:nbview-newline)
      (should (equal "if x:\n    " (ein:view-cell-text ein:nbview--view code))))))

;; T105
(ert-deftest ein:nbview-edit-syntax ()
  (ein:testing-with-edit-nbview
    (let ((code (ein:testing-edit-cell "code" "y = (a, (b)) + 1")))
      (goto-char (car (ein:nbview--source-bounds ein:nbview--view code)))
      (search-forward "(")
      (backward-char)
      (forward-sexp)
      (should (looking-at-p " \\+ 1"))
      (should (equal "# " comment-start))
      (goto-char (cdr (ein:nbview--source-bounds ein:nbview--view code)))
      (newline)
      (comment-dwim nil)
      (should (equal "y = (a, (b)) + 1\n# "
                     (ein:view-cell-text ein:nbview--view code)))
      ;; "#" starts a comment in the code cell.
      (should (nth 4 (syntax-ppss (point))))
      (should (ein:nbview--check-invariants)))))

;; T106
(ert-deftest ein:nbview-edit-completion ()
  (ein:testing-with-edit-nbview
    (let ((code (ein:testing-edit-cell "code" "import o"))
          sent)
      (should (memq #'ein:nbview-completion-at-point completion-at-point-functions))
      ;; (a) a reply
      (cl-letf (((symbol-function 'ein:kernel-live-p) (lambda (_k) t))
                ((symbol-function 'ein:kernel-complete)
                 (lambda (_kernel text pos callback)
                   (setq sent (list text pos))
                   (funcall callback (list :status "ok" :matches ["os" "open"]
                                           :cursor_start 7 :cursor_end 8)))))
        (let ((res (ein:nbview-completion-at-point))
              (src (car (ein:nbview--source-bounds ein:nbview--view code))))
          (should (equal '("import o" 8) sent))
          (should (= (+ src 7) (nth 0 res)))
          (should (= (+ src 8) (nth 1 res)))
          (should (equal '("open" "os")
                         (sort (all-completions "o" (nth 2 res)) #'string<)))
          (should (eq 'no (plist-get (nthcdr 3 res) :exclusive)))
          (completion-at-point)
          (should (member (ein:view-cell-text ein:nbview--view code)
                          '("import o" "import os" "import open")))))
      ;; (b) no reply
      (cl-letf (((symbol-function 'ein:kernel-live-p) (lambda (_k) t))
                ((symbol-function 'ein:kernel-complete) #'ignore))
        (let ((start (float-time)))
          (should-not (ein:nbview-completion-at-point))
          (should (< (- (float-time) start) 0.7))))
      ;; (c) dead kernel (the test kernel has no websocket)
      (setq sent nil)
      (cl-letf (((symbol-function 'ein:kernel-complete)
                 (lambda (&rest _) (setq sent t))))
        (should-not (ein:nbview-completion-at-point))
        (should-not sent))
      ;; Not in a code cell.
      (ein:testing-edit-cell "markdown" "import o")
      (cl-letf (((symbol-function 'ein:kernel-live-p) (lambda (_k) t))
                ((symbol-function 'ein:kernel-complete)
                 (lambda (&rest _) (setq sent t))))
        (should-not (ein:nbview-completion-at-point))
        (should-not sent)))))

;; T114
(ert-deftest ein:nbview-edit-tab ()
  (ein:testing-with-edit-nbview
    (should (eq (keymap-lookup ein:nbview-mode-map "TAB") #'ein:nbview-indent-or-complete))
    (let ((code (ein:testing-edit-cell "code" "def f():\nreturn")))
      (ein:nbview-indent-or-complete)
      (should (equal "def f():\n    return" (ein:view-cell-text ein:nbview--view code)))
      ;; Already indented: complete when `tab-always-indent' says so.
      (let ((tab-always-indent 'complete) called)
        (cl-letf (((symbol-function 'completion-at-point)
                   (lambda () (setq called t))))
          (ein:nbview-indent-or-complete))
        (should called)))))

;; T108
(ert-deftest ein:nbview-edit-non-python-kernel ()
  (let ((ein:notebook-view 'cells))
    (when-let* ((b (get-buffer " *ein-nbview-shadow:python-mode*"))) (kill-buffer b))
    (let (sent)
      (ein:testing-with-notebook-json (ein:testing-edit-notebook-json "javascript" ".js")
        (should (equal "javascript" (ein:nbview--notebook-language)))
        (let ((cell (car (ein:view-cells ein:nbview--view))))
          (should (eq 'js-mode (ein:nbview--cell-mode cell)))
          (font-lock-ensure)
          (let ((src (car (ein:nbview--source-bounds ein:nbview--view cell))))
            (should (memq 'font-lock-keyword-face (ein:testing-edit-faces src)))
            (goto-char src)
            (forward-line 1)
            (let ((this-command 'indent-for-tab-command))
              (indent-for-tab-command))
            (should (equal (format "function f() {\n%sreturn 1;\n}"
                                   (make-string js-indent-level ?\s))
                           (ein:view-cell-text ein:nbview--view cell))))
          (should-not (get-buffer " *ein-nbview-shadow:python-mode*"))
          (cl-letf (((symbol-function 'ein:kernel-live-p) (lambda (_k) t))
                    ((symbol-function 'ein:kernel-complete)
                     (lambda (&rest _) (push 'js sent))))
            (ein:nbview-completion-at-point))))
      (ein:testing-with-notebook-json (ein:testing-edit-notebook-json "brainfuck")
        (let ((cell (car (ein:view-cells ein:nbview--view))))
          (should (eq 'prog-mode (ein:nbview--cell-mode cell)))
          (font-lock-ensure)
          (goto-char (car (ein:nbview--source-bounds ein:nbview--view cell)))
          (indent-for-tab-command)
          (should (ein:nbview--check-invariants))
          (cl-letf (((symbol-function 'ein:kernel-live-p) (lambda (_k) t))
                    ((symbol-function 'ein:kernel-complete)
                     (lambda (&rest _) (push 'bf sent))))
            (ein:nbview-completion-at-point))))
      (should (equal '(bf js) sent))
      (should-not (get-buffer " *ein-nbview-shadow:python-mode*")))))

(ert-deftest ein:nbview-edit-language-mode-is-major ()
  "A notebook language never calls a minor mode or a non-mode function."
  (should (eq 'prog-mode (ein:nbview--language-mode "auto-fill")))
  (should (eq 'prog-mode (ein:nbview--language-mode "no-such-language")))
  (should (eq 'python-mode (ein:nbview--language-mode "python")))
  (let ((major-mode-remap-alist '((python-mode . js-mode))))
    (should (eq 'js-mode (ein:nbview--language-mode "python")))))

(ert-deftest ein:nbview-edit-shadow-buffers-killed ()
  (ein:testing-with-edit-nbview
    (ein:testing-edit-cell "code" "x = 1")
    (font-lock-ensure)
    (should (get-buffer " *ein-nbview-shadow:python-mode*")))
  (should-not (get-buffer " *ein-nbview-shadow:python-mode*")))

(ert-deftest ein:nbview-edit-fontify-leaves-no-undo ()
  (ein:testing-with-edit-nbview
    (ein:testing-edit-cell "code" "def f(): pass")
    (ein:nbview--assert-no-undo-entries
     (lambda ()
       (font-lock-ensure)
       (syntax-propertize (point-max))))))

(provide 'test-ein-nbview-edit)
;;; test-ein-nbview-edit.el ends here
