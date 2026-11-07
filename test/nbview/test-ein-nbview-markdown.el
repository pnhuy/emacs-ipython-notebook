;;; test-ein-nbview-markdown.el --- Markdown preview of the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-markdown.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-markdown.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-markdown.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T127: the pure Markdown renderer, construct by construct.
;; T128: SC-006, toggling preview and edit never changes a source.
;; T129: FR-027b, the preview comes back only on the documented triggers.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-nbview-markdown)
(require 'ein-latex)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

;;; Renderer helpers

(defmacro ein:testing-md-offline (&rest body)
  "Run BODY with every network entry point stubbed to signal."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'url-retrieve)
              (lambda (&rest _) (error "Network access in a renderer")))
             ((symbol-function 'url-retrieve-synchronously)
              (lambda (&rest _) (error "Network access in a renderer")))
             ((symbol-function 'browse-url)
              (lambda (&rest _) (error "A link opened by itself"))))
     ,@body))

(defun ein:testing-md (source &rest context)
  "Render SOURCE offline with CONTEXT (default: a terminal)."
  (ein:testing-md-offline
    (ein:nbview-render-markdown
     source (append context (list :graphic nil :window-width 800)))))

(defun ein:testing-md-faces (string text)
  "Faces at the first occurrence of TEXT in STRING, as a list."
  (let ((i (string-search text string)))
    (should i)
    (ensure-list (get-text-property i 'face string))))

(defun ein:testing-md-has-face (string text face)
  (memq face (ein:testing-md-faces string text)))

(defun ein:testing-md-lines (string)
  (split-string (substring-no-properties string) "\n" t))

;;; T127: constructs

(ert-deftest ein:nbview-md-headings ()
  (let ((s (ein:testing-md "# H1\n\n### Third")))
    (should (string-search "H1" s))
    (should-not (string-search "#" s))
    (should (ein:testing-md-has-face s "H1" 'ein:nbview-md-h1))
    (should (ein:testing-md-has-face s "Third" 'ein:nbview-md-h3)))
  (let ((s (ein:testing-md "Title\n=====\n\nSub\n---")))
    (should (ein:testing-md-has-face s "Title" 'ein:nbview-md-h1))
    (should (ein:testing-md-has-face s "Sub" 'ein:nbview-md-h2))
    (should-not (string-search "===" s))))

(ert-deftest ein:nbview-md-inline ()
  (let ((s (ein:testing-md "a **b** *i* ~~s~~ `c` __u__ _e_")))
    (should (equal "a b i s c u e" (substring-no-properties s)))
    (should (ein:testing-md-has-face s "b" 'bold))
    (should (ein:testing-md-has-face s "u" 'bold))
    (should (ein:testing-md-has-face s "i" 'italic))
    (should (ein:testing-md-has-face s "e" 'italic))
    (should (ein:testing-md-has-face s "s" 'ein:nbview-md-strike))
    (should (ein:testing-md-has-face s "c" 'ein:nbview-md-code)))
  ;; Nested emphasis and escapes.
  (let ((s (ein:testing-md "**bold *both***  \\*lit\\*")))
    (should (ein:testing-md-has-face s "both" 'bold))
    (should (ein:testing-md-has-face s "both" 'italic))
    (should (string-search "*lit*" s)))
  ;; Inline HTML is literal text.
  (should (string-search "<b>x</b>" (ein:testing-md "<b>x</b> <script>alert(1)</script>"))))

(ert-deftest ein:nbview-md-links ()
  (let* ((s (ein:testing-md "see [t](http://x) and <https://y.org>"))
         (i (string-search "t" s)))
    (should (equal "see t and https://y.org" (substring-no-properties s)))
    (should (get-text-property i 'button s))
    (should (equal "http://x" (get-text-property i 'ein-url s)))
    (should (ein:testing-md-has-face s "t" 'ein:nbview-md-link))
    (should (equal "https://y.org"
                   (get-text-property (string-search "https" s) 'ein-url s)))))

(ert-deftest ein:nbview-md-lists ()
  (let ((tty (ein:testing-md "- [x] done\n- [ ] todo\n- plain\n  - nested\n1. one"))
        (gui (ein:testing-md-offline
               (ein:nbview-render-markdown "- [x] done\n- [ ] todo" '(:graphic t)))))
    (should (equal '("[x] done" "[ ] todo" "• plain" "  • nested" "1. one")
                   (ein:testing-md-lines tty)))
    (should (equal '("☑ done" "☐ todo") (ein:testing-md-lines gui)))))

(ert-deftest ein:nbview-md-code-block ()
  (let ((s (ein:testing-md "Text\n\n```python\ndef f():\n    return 1\n```\n\nafter")))
    (should (string-search "def f():\n    return 1" s))
    (should-not (string-search "```" s))
    (should (ein:testing-md-has-face s "def" 'font-lock-keyword-face))
    (should (ein:testing-md-has-face s "return" 'ein:nbview-md-code))
    (should (string-search "after" s))))

(ert-deftest ein:nbview-md-table ()
  (let* ((s (ein:testing-md "| a | bb |\n|:--|--:|\n| ccc | d |\n| `e` | **f** |"))
         (lines (ein:testing-md-lines s))
         (rows (cl-remove-if (lambda (l) (string-match-p "\\`[─┼ ]+\\'" l)) lines)))
    (should-not (string-search "|" s))
    (should-not (string-search ":--" s))
    (should (= 4 (length lines)))
    (should (= 1 (length (delete-dups (mapcar #'string-width lines)))))
    ;; Left aligned: "a" and "ccc" start at the same column.
    (should (= (string-search "a" (nth 0 rows)) (string-search "ccc" (nth 1 rows))))
    ;; Right aligned: "bb" and "d" end at the same column.
    (should (= (+ 2 (string-search "bb" (nth 0 rows))) (1+ (string-search "d" (nth 1 rows)))))
    (should (ein:testing-md-has-face s "a" 'ein:nbview-md-table))
    (should (ein:testing-md-has-face s "f" 'bold))))

(ert-deftest ein:nbview-md-images ()
  (ein:testing-with-notebook-file (ein:testing-fixture "attachments.ipynb")
    (let* ((cell (car (ein:worksheet-get-cells ein:%worksheet%)))
           (att (plist-get (oref cell raw) :attachments))
           (src "![a](attachment:a.png)"))
      (should (equal "[image a]" (substring-no-properties
                                  (ein:testing-md src :attachments att))))
      (when (image-type-available-p 'png)
        (let* ((s (ein:testing-md-offline
                    (ein:nbview-render-markdown
                     src (list :graphic t :window-width 800 :attachments att))))
               (img (get-text-property 0 'display s)))
          (should (eq 'image (car-safe img)))
          (should (eq 'png (plist-get (cdr img) :type))))
        ;; A missing attachment is a placeholder, not an error.
        (should (equal "[image b]"
                       (substring-no-properties
                        (ein:testing-md-offline
                          (ein:nbview-render-markdown
                           "![b](attachment:b.png)" (list :graphic t :attachments att))))))
        ;; data: URIs.
        (let* ((data (plist-get (plist-get att :a.png) :image/png))
               (s (ein:testing-md-offline
                    (ein:nbview-render-markdown
                     (format "![d](data:image/png;base64,%s)" data) '(:graphic t)))))
          (should (eq 'image (car-safe (get-text-property 0 'display s)))))))))

(ert-deftest ein:nbview-md-local-image ()
  (let* ((dir (make-temp-file "ein-md-" t))
         (png (base64-decode-string
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'binary))
            (write-region png nil (expand-file-name "p.png" dir) nil 'silent))
          (when (image-type-available-p 'png)
            (should (eq 'image (car-safe
                                (get-text-property
                                 0 'display
                                 (ein:testing-md-offline
                                   (ein:nbview-render-markdown
                                    "![p](p.png)" (list :graphic t :notebook-dir dir))))))))
          ;; Without a local notebook directory, or outside it: placeholder.
          (should (equal "[image p]" (substring-no-properties
                                      (ein:testing-md-offline
                                        (ein:nbview-render-markdown "![p](p.png)" '(:graphic t))))))
          (should (equal "[image q]" (substring-no-properties
                                      (ein:testing-md-offline
                                        (ein:nbview-render-markdown
                                         "![q](../../etc/passwd)"
                                         (list :graphic t :notebook-dir dir)))))))
      (delete-directory dir t))))

(ert-deftest ein:nbview-md-remote-image ()
  (let ((ein:nbview-fetch-remote-images nil))
    (let ((s (ein:testing-md-offline
               (ein:nbview-render-markdown "![r](https://x/y.png)" '(:graphic t)))))
      (should (equal "[image r]" (substring-no-properties s)))
      (should (equal "https://x/y.png" (get-text-property 1 'ein-url s)))
      (should-not (get-text-property 0 'display s)))))

(ert-deftest ein:nbview-md-math-text ()
  (let ((ein:latex-render-method 'text))
    (let ((s (ein:testing-md "$\\alpha^2$ and \\(\\beta\\)")))
      (should (equal "α² and β" (substring-no-properties s)))
      (should (ein:testing-md-has-face s "α²" 'ein:latex-face)))
    (let ((s (ein:testing-md "$$\n\\sum x_i \\le \\infty\n$$")))
      (should (string-search "∑ xᵢ ≤ ∞" s))
      (should (ein:testing-md-has-face s "∑" 'ein:latex-face)))
    ;; A lone dollar is text.
    (should (equal "costs $5" (substring-no-properties (ein:testing-md "costs $5"))))))

(ert-deftest ein:nbview-md-blocks ()
  (let ((s (ein:testing-md "> quoted *it*\n\n---\n\npara one\nline two")))
    (should (string-search "quoted it" s))
    (should-not (string-search ">" s))
    (should (string-search "─" s))
    (should (string-search "para one line two" s))))

(ert-deftest ein:nbview-md-malformed ()
  (dolist (src '("```python\nx = 1" "| a |\n|---" "**open" "[x](" "![a](" "$$\nx" "$x" "" "\n\n"
                 "* * *" "#nohead" "<div>"))
    (let ((s (ein:testing-md src)))
      (should (stringp s))))
  (should (string-search "x = 1" (ein:testing-md "```python\nx = 1")))
  (should (string-search "**open" (ein:testing-md "**open")))
  (should (string-search "#nohead" (ein:testing-md "#nohead"))))

(ert-deftest ein:nbview-md-source-not-mutated ()
  (let* ((src (propertize "# T\n\n**b** [l](http://x) $x$ | a |" 'face 'bold))
         (copy (copy-sequence src)))
    (ein:testing-md src)
    (should (equal-including-properties src copy))))

;;; View helpers

(defun ein:testing-md-notebook-json (cells)
  "An nbformat 4.5 notebook of CELLS, each (TYPE . SOURCE)."
  (decode-coding-string
   (json-serialize
   `((cells . ,(vconcat
                (cl-loop for (type . src) in cells for i from 0
                         collect `((cell_type . ,type)
                                   (id . ,(format "c%02d" i))
                                   (metadata . ,(make-hash-table))
                                   (source . ,src)
                                   ,@(and (equal type "code")
                                          `((outputs . []) (execution_count . :null)))))))
     (metadata . ,(make-hash-table))
     (nbformat . 4)
     (nbformat_minor . 5)))
   'utf-8))

(defmacro ein:testing-with-md-nbview (cells &rest body)
  "Open a notebook of CELLS in the cells view, shown in the selected window."
  (declare (indent 1) (debug t))
  `(let ((ein:notebook-view 'cells)
         (ein:latex-render-method 'text))
     (ein:testing-with-notebook-json (ein:testing-md-notebook-json ,cells)
       (set-window-buffer (selected-window) (current-buffer))
       ,@body)))

(defun ein:testing-md-cell (n)
  (nth n (ein:view-cells ein:nbview--view)))

(defun ein:testing-md-preview (cell)
  "The string previewing CELL, or nil."
  (when-let* ((ov (ein:nbview--preview-overlay ein:nbview--view cell)))
    (overlay-get ov 'after-string)))

(defun ein:testing-md-source (cell)
  (ein:view-cell-text ein:nbview--view cell))

(defun ein:testing-md-command (fn &rest args)
  "Run FN with ARGS the way the command loop runs a command."
  (undo-boundary)
  (setq this-command fn)
  (prog1 (apply fn args)
    (setq last-command this-command)
    (ein:nbview--post-command)))

(defvar ein:testing-md-renders 0)

(defmacro ein:testing-md-counting (&rest body)
  "Run BODY counting calls of `ein:nbview-render-markdown'."
  (declare (indent 0) (debug t))
  (let ((advice (make-symbol "advice")))
    `(let ((ein:testing-md-renders 0)
           (,advice (lambda (&rest _) (cl-incf ein:testing-md-renders))))
       (advice-add 'ein:nbview-render-markdown :before ,advice)
       (unwind-protect (progn ,@body)
         (advice-remove 'ein:nbview-render-markdown ,advice)))))

(defun ein:testing-md-keys (keys)
  (execute-kbd-macro (kbd keys)))

;;; Preview basics

(ert-deftest ein:nbview-md-preview-shown ()
  (ein:testing-with-md-nbview '(("markdown" . "# Title\n\n**bold**")
                                ("code" . "x = 1"))
    (let ((md (ein:testing-md-cell 0))
          (code (ein:testing-md-cell 1)))
      (should (equal "Title\n\nbold" (substring-no-properties (ein:testing-md-preview md))))
      (should-not (ein:testing-md-preview code))
      ;; The buffer text is the source; the preview is display only.
      (should (equal "# Title\n\n**bold**" (ein:testing-md-source md)))
      ;; The source is hidden, not replaced by a `display' string:
      ;; Emacs ignores image properties nested in one.
      (let ((ov (ein:nbview--preview-overlay ein:nbview--view md)))
        (should (overlay-get ov 'invisible))
        (should-not (overlay-get ov 'display)))
      (should (ein:nbview--check-invariants))
      ;; Editing shows the source.
      (ein:nbview-select-cell md)
      (ein:nbview-edit-cell)
      (should-not (ein:testing-md-preview md))
      (ein:nbview-command-state)
      (should (ein:testing-md-preview md))
      ;; Typing in edit state changes the source, and the preview follows.
      (ein:nbview-edit-cell)
      (goto-char (cdr (ein:nbview--source-bounds ein:nbview--view md)))
      (insert " more")
      (ein:nbview-command-state)
      (should (equal "Title\n\nbold more" (substring-no-properties (ein:testing-md-preview md)))))))

(ert-deftest ein:nbview-md-preview-is-after-string ()
  "The preview is the hiding overlay's `after-string', never a `before-string'.
The source is invisible, so the display shows the preview where the
source ends, at the footer.  There, `before-string's of overlays that
start earlier and of the footer are drawn in an order that puts the
footer's bottom rule above the preview (found by T163: the rule was
drawn left of the heading).  `after-string's of overlays ending there
always come before the `before-string's of overlays starting there."
  (ein:testing-with-md-nbview '(("markdown" . "# Smoke\n\nSome *text*.")
                                ("code" . "x = 1"))
    (let* ((md (ein:testing-md-cell 0))
           (ov (ein:nbview--preview-overlay ein:nbview--view md)))
      (should-not (overlay-get ov 'before-string))
      (should (equal "Smoke\n\nSome text."
                     (substring-no-properties (overlay-get ov 'after-string))))
      ;; The footer starts where the hidden source ends.
      (should (= (overlay-end ov)
                 (overlay-start (ein:nbview--footer-overlay ein:nbview--view md)))))))

(ert-deftest ein:nbview-md-click-preview-edits ()
  "A click on the preview shows the source for editing (FR-024a).
Emacs reports a click on an `after-string' at the overlay's end, the
footer, with the string; that must not read as a click on the footer
(found by T163).  Same for the `[source hidden]' placeholder."
  (ein:testing-with-md-nbview '(("code" . "x = 1") ("markdown" . "# Notes\n\ntext"))
    (let* ((view ein:nbview--view)
           (code (ein:testing-md-cell 0))
           (md (ein:testing-md-cell 1))
           (click (lambda (ov)
                    ;; What Emacs reports for a click on OV's `after-string'.
                    (list 'mouse-1
                          (list (selected-window) (overlay-end ov) '(0 . 0) 0
                                (cons (overlay-get ov 'after-string) 3)
                                (overlay-end ov))))))
      (ein:nbview-select-cell code)
      (ein:nbview-mouse-select
       (funcall click (ein:nbview--preview-overlay view md)))
      (should (eq md (oref view selected)))
      (should (eq ein:nbview--state 'edit))
      (should-not (ein:testing-md-preview md))
      (should (= (point) (car (ein:nbview--source-bounds view md))))
      ;; The hidden-source placeholder of a code cell.
      (ein:nbview-command-state)
      (ein:nbview-select-cell code)
      (ein:nbview-toggle-input)
      (ein:nbview-select-cell md)
      (ein:nbview-mouse-select (funcall click (ein:nbview--input-overlay view code)))
      (should (eq code (oref view selected)))
      (should (eq ein:nbview--state 'edit))
      (should-not (ein:nbview--input-overlay view code))
      (should (ein:nbview--check-invariants)))))

(ert-deftest ein:nbview-md-theme-change-rerenders ()
  "Enabling or disabling a theme renders previews and outputs again.
LaTeX images are drawn in the theme's foreground, so after a switch to
a dark theme they were black on black (found by T163)."
  (ein:testing-with-md-nbview '(("markdown" . "Euler: $x$") ("code" . "x = 1"))
    (let ((md (ein:testing-md-cell 0))
          (code (ein:testing-md-cell 1))
          (footers nil))
      (should (memq #'ein:nbview--theme-changed enable-theme-functions))
      (should (memq #'ein:nbview--theme-changed disable-theme-functions))
      (cl-letf* ((orig (symbol-function 'ein:nbview--render-footer))
                 ((symbol-function 'ein:nbview-render-markdown)
                  (lambda (&rest _) "RERENDERED"))
                 ((symbol-function 'ein:nbview--render-footer)
                  (lambda (view cell) (push cell footers) (funcall orig view cell))))
        (run-hook-with-args 'enable-theme-functions 'some-theme)
        (should (equal "RERENDERED" (ein:testing-md-preview md)))
        (should (memq code footers))
        (setq footers nil)
        (run-hook-with-args 'disable-theme-functions 'some-theme)
        (should (memq code footers)))
      (should-not (buffer-modified-p))
      (should (ein:nbview--check-invariants)))))

(ert-deftest ein:nbview-md-preview-structure ()
  "The preview survives insertion, conversion, moves, deletion and undo."
  (ein:testing-with-md-nbview '(("markdown" . "# A") ("code" . "x = 1") ("markdown" . "# B"))
    (let ((a (ein:testing-md-cell 0)) (b (ein:testing-md-cell 2)))
      (ein:nbview-select-cell b)
      (ein:testing-md-command #'ein:nbview-move-cell-up)
      (should (equal "B" (substring-no-properties (ein:testing-md-preview b))))
      (ein:nbview-select-cell a)
      (ein:testing-md-command #'ein:nbview-delete-cell)
      (should-not (ein:nbview--preview-overlay ein:nbview--view a))
      (ein:testing-md-command #'ein:nbview-undo)
      (let ((a2 (ein:testing-md-cell 0)))
        (should (equal "# A" (ein:testing-md-source a2)))
        (should (equal "A" (substring-no-properties (ein:testing-md-preview a2)))))
      ;; Conversion: code to markdown gets a preview; back to code loses it.
      (let ((code (cl-find-if #'ein:codecell-p (ein:view-cells ein:nbview--view))))
        (ein:nbview-select-cell code)
        (ein:nbview-to-markdown)
        (let ((md (ein:nbview--cell-at (point))))
          (should (equal "x = 1" (substring-no-properties (ein:testing-md-preview md))))
          (ein:nbview-to-code)
          (should-not (ein:testing-md-preview (ein:nbview--cell-at (point))))))
      (should (= 1 (length (delete-dups
                            (mapcar (lambda (ov) (overlay-get ov 'ein-nbview-preview))
                                    (cl-remove-if-not
                                     (lambda (ov) (overlay-get ov 'ein-nbview-preview))
                                     (overlays-in (point-min) (point-max))))))))
      (should (ein:nbview--check-invariants)))))

;;; T128: SC-006

(defconst ein:testing-md-samples
  '("# Heading\n\nText with **bold** and *italic*."
    "Setext\n======\n\npara"
    "- a\n- b\n  - c\n- [x] done\n- [ ] todo"
    "1. one\n2. two\n\n3) three"
    "```python\ndef f(x):\n    return x * 2\n```"
    "```\nno language\n```"
    "| a | b |\n|---|:-:|\n| 1 | 2 |"
    "![img](attachment:missing.png) and ![remote](https://example.org/x.png)"
    "Inline $\\alpha + \\beta$ and $$x^2$$"
    "$$\n\\int_0^1 f(x)\\,dx\n$$"
    "> quote\n> more\n\n---"
    "<div>html <b>kept</b></div>"
    "Trailing spaces   \nand\ttabs\t"
    "~~strike~~ `code` [link](http://example.org)"
    "Unicode: café ✓ 漢字 🙂"
    "```python\nunclosed fence"
    "\\*escaped\\* and \\$5"
    "\n\nleading and trailing blank lines\n\n"
    "* * *\n\n#nohead\n\n####### seven"))

(defun ein:testing-md-fixture-sources ()
  "Markdown cell sources of the round-trip fixtures."
  (cl-loop for f in (directory-files (ein:testing-fixture "") t "\\.ipynb\\'")
           append (cl-loop for c across (gethash "cells" (json-parse-string
                                                         (with-temp-buffer
                                                           (insert-file-contents f)
                                                           (buffer-string))))
                           when (equal "markdown" (gethash "cell_type" c))
                           collect (let ((s (gethash "source" c)))
                                     (if (stringp s) s (mapconcat #'identity s ""))))))

(ert-deftest ein:nbview-md-toggle-preserves-source ()
  (let ((sources (seq-take (append (ein:testing-md-fixture-sources) ein:testing-md-samples) 20)))
    (should (= 20 (length sources)))
    (ein:testing-with-md-nbview (mapcar (lambda (s) (cons "markdown" s)) sources)
      (let ((json (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))
            (cells (ein:view-cells ein:nbview--view)))
        (should (= 20 (length cells)))
        (dotimes (_ 3)
          (dolist (cell cells)
            (ein:nbview-select-cell cell)
            (should (or (ein:testing-md-preview cell)
                        (string-empty-p (string-trim (ein:testing-md-source cell)))))
            (ein:nbview-edit-cell)
            (should-not (ein:testing-md-preview cell))
            (ein:nbview-command-state)))
        (cl-loop for cell in cells for src in sources
                 do (should (equal src (ein:testing-md-source cell))))
        (should (equal json (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%))))
        (should (ein:nbview--check-invariants))))))

;;; T129: FR-027b triggers

(defconst ein:testing-md-triggers
  '(("markdown" . "# Title\n\nline two\n\nline three")
    ("code" . "x = 1")
    ("markdown" . "*other*")))

(ert-deftest ein:nbview-md-no-restore-on-motion ()
  (ein:testing-with-md-nbview ein:testing-md-triggers
    (let ((md (ein:testing-md-cell 0)))
      (ein:nbview-select-cell md)
      (ein:testing-md-keys "RET")
      (should-not (ein:testing-md-preview md))
      (ein:testing-md-counting
        (ein:testing-md-keys "C-n")
        (ein:testing-md-keys "C-n")
        (ein:testing-md-keys "C-p")
        (ein:testing-md-keys "C-s three RET")
        (ignore-errors (scroll-up 1))
        (ein:nbview--post-command)
        (should (eq md (ein:nbview--cell-at (point))))
        (should (eq ein:nbview--state 'edit))
        (should-not (ein:testing-md-preview md))
        (should (= 0 ein:testing-md-renders))))))

(ert-deftest ein:nbview-md-restore-triggers ()
  (ein:testing-with-md-nbview ein:testing-md-triggers
    (let ((md (ein:testing-md-cell 0))
          (other (ein:testing-md-cell 2)))
      (cl-flet ((edit-md ()
                  (ein:nbview-command-state)
                  (ein:nbview-select-cell md)
                  (ein:testing-md-keys "RET")
                  (should (eq ein:nbview--state 'edit))
                  (should-not (ein:testing-md-preview md))))
        ;; Esc.
        (edit-md)
        (ein:testing-md-counting
          (ein:testing-md-keys "<escape>")
          (should (= 1 ein:testing-md-renders)))
        (should (ein:testing-md-preview md))
        ;; C-RET renders without moving.
        (edit-md)
        (ein:testing-md-keys "C-<return>")
        (should (ein:testing-md-preview md))
        (should (eq md (ein:nbview--cell-at (point))))
        ;; S-RET renders and advances.
        (edit-md)
        (ein:testing-md-keys "S-<return>")
        (should (ein:testing-md-preview md))
        (should (ein:codecell-p (ein:nbview--cell-at (point))))
        ;; Selecting another cell while editing.
        (edit-md)
        (ein:testing-md-keys "C-c C-n")
        (should (ein:testing-md-preview md))
        (should (eq ein:nbview--state 'edit))
        ;; Moving point into another cell (as a click does).
        (edit-md)
        (goto-char (car (ein:nbview--source-bounds ein:nbview--view other)))
        (ein:nbview--post-command)
        (should (ein:testing-md-preview md))
        (should-not (ein:testing-md-preview other))))))

(ert-deftest ein:nbview-md-preview-disabled ()
  (let ((ein:nbview-markdown-preview nil))
    (ein:testing-with-md-nbview ein:testing-md-triggers
      (should-not (ein:testing-md-preview (ein:testing-md-cell 0)))
      (ein:nbview-select-cell (ein:testing-md-cell 0))
      (ein:nbview-edit-cell)
      (ein:nbview-command-state)
      (should-not (ein:testing-md-preview (ein:testing-md-cell 0)))))
  ;; The buffer toggle.
  (ein:testing-with-md-nbview ein:testing-md-triggers
    (should (ein:testing-md-preview (ein:testing-md-cell 0)))
    (should (eq (key-binding (kbd "C-c C-v")) 'ein:nbview-toggle-markdown-preview))
    (ein:nbview-toggle-markdown-preview)
    (should-not (ein:testing-md-preview (ein:testing-md-cell 0)))
    (should-not (ein:testing-md-preview (ein:testing-md-cell 2)))
    (ein:nbview-toggle-markdown-preview)
    (should (ein:testing-md-preview (ein:testing-md-cell 0)))
    (should (ein:testing-md-preview (ein:testing-md-cell 2)))))

(ert-deftest ein:nbview-md-renderer-error ()
  (ein:testing-with-md-nbview ein:testing-md-triggers
    (let ((md (ein:testing-md-cell 0)))
      (ein:nbview-select-cell md)
      (ein:nbview-edit-cell)
      (cl-letf (((symbol-function 'ein:nbview-render-markdown)
                 (lambda (&rest _) (error "Boom"))))
        (ein:nbview-command-state)
        (should-not (ein:testing-md-preview md))
        (let ((ov (ein:nbview--preview-overlay ein:nbview--view md)))
          (should ov)
          (should (eq 'ein:nbview-md-error (overlay-get ov 'face))))
        ;; Editing still works.
        (ein:nbview-edit-cell)
        (insert "x")
        (should (string-prefix-p "x# Title" (ein:testing-md-source md)))
        (ein:nbview-command-state)
        (should (ein:nbview--check-invariants))))))

(provide 'test-ein-nbview-markdown)

;;; test-ein-nbview-markdown.el ends here
