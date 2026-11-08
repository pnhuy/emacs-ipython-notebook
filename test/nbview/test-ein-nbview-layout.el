;;; test-ein-nbview-layout.el --- Cells view layout invariants -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-layout.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-layout.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-layout.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T080: data-model.md §8 invariants of the cells view, before and
;; after structural edits; sources equal the model; decorations never
;; reach the saved notebook.

;;; Code:

(require 'ert)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defmacro ein:testing-with-nbview (fixture &rest body)
  "Open round-trip FIXTURE in the cells view and run BODY in its buffer."
  (declare (indent 1) (debug t))
  `(let ((ein:notebook-view 'cells))
     (ein:testing-with-notebook-file (ein:testing-fixture ,fixture)
       ,@body)))

(defun ein:testing-nbview-json ()
  "The current notebook serialized."
  (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))

(defun ein:testing-nbview-source-texts ()
  "Buffer text of every cell source, in order."
  (mapcar (lambda (cell)
            (let ((b (ein:nbview--source-bounds ein:nbview--view cell)))
              (buffer-substring-no-properties (car b) (cdr b))))
          (ein:view-cells ein:nbview--view)))

(defun ein:testing-nbview-file-json (fixture)
  (with-temp-buffer
    (insert-file-contents (ein:testing-fixture fixture))
    (buffer-string)))

;; (a) (b) (c)
(ert-deftest ein:nbview-layout-render-invariants ()
  (dolist (fixture '("smoke.ipynb" "multimime.ipynb"))
    (ein:testing-with-nbview fixture
      (should (ein:nbview-p ein:nbview--view))
      (should (eq major-mode 'ein:nbview-mode))
      (should (ein:nbview--check-invariants))
      (let ((cells (ein:worksheet-get-cells ein:%worksheet%)))
        (should cells)
        (should (equal (mapcar (lambda (c) (slot-value c 'input)) cells)
                       (ein:testing-nbview-source-texts))))
      (should (ein:testing-json-semantic-equal
               (ein:testing-nbview-file-json fixture)
               (ein:testing-nbview-json)))
      (should-not (buffer-modified-p)))))

(ert-deftest ein:nbview-layout-no-autoexec ()
  "Opening never sends an execute request."
  (let (sent)
    (cl-letf (((symbol-function 'ein:kernel-execute)
               (lambda (&rest _) (setq sent t))))
      (ein:testing-with-nbview "smoke.ipynb"
        (should-not sent)))))

;; (d)
(ert-deftest ein:nbview-layout-structural-edits ()
  (ein:testing-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (first (car (ein:view-cells view))))
      (ein:nbview-select-cell first)
      (let ((new (ein:nbview-insert-cell-below)))
        (should (ein:nbview--check-invariants))
        (should (= 3 (length (ein:view-cells view))))
        (should (eq new (nth 1 (ein:view-cells view))))
        (insert "x = 1")
        (should (equal "x = 1" (ein:view-cell-text view new)))
        (ein:nbview-move-cell-down)
        (should (ein:nbview--check-invariants))
        (should (eq new (nth 2 (ein:view-cells view))))
        (should (equal "x = 1" (ein:view-cell-text view new)))
        (should (eq new (ein:nbview--cell-at (point))))
        ;; The selection overlay follows the moved cell.
        (let ((ov (oref view overlay)))
          (should (= (overlay-start ov) (ein:nbview--header-pos view new)))
          (should (= (overlay-end ov)
                     (1+ (ein:nbview--footer-pos (ein:nbview--header-pos view new))))))
        (ein:nbview-move-cell-up)
        (should (eq new (nth 1 (ein:view-cells view))))
        (ein:nbview-to-markdown)
        (should (ein:nbview--check-invariants))
        (let ((md (nth 1 (ein:view-cells view))))
          (should (ein:markdowncell-p md))
          (should (equal "x = 1" (ein:view-cell-text view md))))
        (ein:nbview-delete-cell)
        (should (ein:nbview--check-invariants))
        (should (= 2 (length (ein:view-cells view))))
        (should (ein:testing-json-semantic-equal
                 (ein:testing-nbview-file-json "smoke.ipynb")
                 (ein:testing-nbview-json)))))))

(ert-deftest ein:nbview-layout-typing-stays-in-cell ()
  "Typing at a source boundary lands in that source, never between cells."
  (ein:testing-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cells (ein:view-cells view))
           (b (ein:nbview--source-bounds view (car cells))))
      (goto-char (cdr b))
      (insert "!")
      (goto-char (car (ein:nbview--source-bounds view (cadr cells))))
      (insert "#")
      (should (ein:nbview--check-invariants))
      (should (string-suffix-p "!" (ein:view-cell-text view (car cells))))
      (should (string-prefix-p "#" (ein:view-cell-text view (cadr cells))))
      ;; Headers and footers are read-only.
      (should-error (let ((inhibit-read-only nil))
                      (goto-char (ein:nbview--header-pos view (cadr cells)))
                      (delete-char 1))))))

;; (e)
(ert-deftest ein:nbview-layout-no-polymode ()
  "The cells view does not load polymode."
  (let* ((root (expand-file-name "../.." (file-name-directory
                                          (locate-library "test-ein-nbview-layout"))))
         (deps (or (getenv "EIN_DEPS_DIR") (expand-file-name ".deps/elpa" root)))
         (out (with-temp-buffer
                (call-process
                 (expand-file-name invocation-name invocation-directory)
                 nil t nil "-Q" "--batch"
                 "--eval" (format "(setq package-user-dir %S)" deps)
                 "--eval" "(package-initialize)"
                 "-L" (expand-file-name "lisp" root)
                 "-L" (expand-file-name "test" root)
                 "--eval" "(progn (require 'ein-testing-notebook) (require 'ein-testing-nbformat))"
                 "--eval"
                 (format "(let ((ein:notebook-view 'cells)) (ein:testing-with-notebook-file %S (princ (format \"POLY=%%s\" (featurep 'poly-ein)))))"
                         (expand-file-name "test/fixtures/roundtrip/smoke.ipynb" root)))
                (buffer-string))))
    (should (string-match-p "POLY=nil" out))))

;; (f)
(ert-deftest ein:nbview-layout-rule-fallback ()
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_c) nil)))
    (should (string-match-p "\\`-+\\'" (ein:nbview--rule)))
    (should (equal "| " (substring-no-properties
                         (ein:nbview--bar 'ein:nbview-cell-bar)))))
  (cl-letf (((symbol-function 'char-displayable-p) (lambda (_c) t)))
    (should (string-match-p "\\`─+\\'" (ein:nbview--rule)))))

(ert-deftest ein:nbview-layout-rule-fits-wide-glyphs ()
  "A header rule leaves room for its toolbar by measured width, not columns.
Regression: in GUI frames the toolbar's symbols come from fallback fonts
wider than their `string-width', and the toolbar wrapped to a new line."
  (let* ((avail 100)
         (measure (lambda (s)
                    ;; Every non-ASCII glyph is three units wide.
                    (cl-loop for c across s sum (if (< c 128) 1 3))))
         (label "Markdown")
         (toolbar "▶ ＋ ✕ ↑ ↓ ⋯"))
    (cl-letf (((symbol-function 'ein:nbview--line-metrics)
               (lambda () (cons avail measure)))
              ((symbol-function 'char-displayable-p) (lambda (_c) t)))
      (let* ((used (concat label "  " toolbar))
             (header (funcall measure (concat label " " (ein:nbview--rule used)
                                              " " toolbar)))
             (footer (funcall measure (ein:nbview--rule))))
        (should (<= header avail))
        ;; Header and footer rules end within one rule glyph of each other.
        (should (<= (abs (- header footer)) 3))))))

(ert-deftest ein:nbview-layout-rules-follow-window-width ()
  "Rules are drawn again for a new line width, without the outputs.
Regression: footers drawn before the buffer had a window kept the
80 column fallback width."
  (ein:testing-with-nbview "smoke.ipynb"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((view ein:nbview--view)
             (code (cadr (ein:view-cells view)))
             (room 40)
             (renders 0)
             (header-length
              (lambda ()
                (length (get-text-property (ein:nbview--header-pos view code)
                                           'display))))
             (narrow-header nil)
             (rule-length
              (lambda ()
                (let ((s (ein:nbview--footer-rendered view code)))
                  (string-match "\\([─-]+\\)\n\\'" s)
                  (length (match-string 1 s))))))
        (setf (slot-value code 'outputs)
              (list (list :output_type "stream" :name "stdout" :text "hello\n")))
        (cl-letf (((symbol-function 'ein:nbview--line-metrics)
                   (lambda () (cons room #'string-width))))
          (ein:nbview--render-footer view code)
          (ein:nbview--window-changed (selected-window))
          (should (= 40 (funcall rule-length)))
          (setq narrow-header (funcall header-length))
          (advice-add 'ein:nbview-render-outputs :before
                      (lambda (&rest _) (cl-incf renders)) '((name . count)))
          (unwind-protect
              (progn
                (setq room 70)
                (ein:nbview--window-changed (selected-window))
                (should (= 70 (funcall rule-length)))
                (should (string-match-p "hello" (ein:nbview--footer-rendered view code)))
                (should (= (+ narrow-header 30) (funcall header-length)))
                (should (= 0 renders)))
            (advice-remove 'ein:nbview-render-outputs 'count)))))))

(ert-deftest ein:nbview-layout-rules-follow-line-numbers ()
  "Turning line numbers off or on redraws the rules to the new width.
The window keeps its size, so `window-size-change-functions' do not run."
  (ein:testing-with-nbview "smoke.ipynb"
    (save-window-excursion
      (delete-other-windows)
      (switch-to-buffer (current-buffer))
      (let* ((view ein:nbview--view)
             (cell (car (ein:view-cells view)))
             (header-length
              (lambda ()
                (length (get-text-property (ein:nbview--header-pos view cell)
                                           'display)))))
        ;; Until the next redisplay, the width of the line numbers is
        ;; the last one drawn, as it is right after turning them off.
        (cl-letf (((symbol-function 'line-number-display-width)
                   (lambda (&rest _) 4)))
          (display-line-numbers-mode 1)
          (ein:nbview--window-changed (selected-window))
          (let ((with-numbers (funcall header-length)))
            (display-line-numbers-mode -1)
            (should (= (funcall header-length) (+ with-numbers 4)))
            (display-line-numbers-mode 1)
            (should (= (funcall header-length) with-numbers))))))))

(ert-deftest ein:nbview-layout-output-separator ()
  "A rule separates a code cell's source from its outputs, only when it has any."
  (ein:testing-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view))))
      (setf (slot-value code 'outputs) nil)
      (let ((s (ein:nbview--footer-body view code)))
        (should-not (text-property-any 0 (length s)
                                       'face 'ein:nbview-output-separator s)))
      (setf (slot-value code 'outputs)
            (list (list :output_type "stream" :name "stdout" :text "hello\n")))
      (ein:nbview--render-footer view code)
      (let ((s (ein:nbview--footer-rendered view code)))
        (should (string-match "^\\([┄-]+\\)\nhello" s))
        (should (eq 'ein:nbview-output-separator
                    (get-text-property (match-beginning 1) 'face s)))))))

;; (g)
(ert-deftest ein:nbview-layout-decoration-like-source-roundtrips ()
  (ein:testing-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cells (ein:view-cells view))
           (code "▎ x\n[1]\n────\n| y")
           (md "- [ ] todo\n[ ] box"))
      (ein:view-set-cell-text view (cadr cells) code)
      (ein:view-set-cell-text view (car cells) md)
      (should (ein:nbview--check-invariants))
      (let ((json (json-parse-string (ein:testing-nbview-json)
                                     :object-type 'alist :array-type 'list)))
        (should (equal (list md code)
                       (mapcar (lambda (c)
                                 (let ((s (alist-get 'source c)))
                                   (if (stringp s) s (apply #'concat s))))
                               (alist-get 'cells json))))))))

;; (h)
(ert-deftest ein:nbview-layout-two-windows ()
  (ein:testing-with-nbview "smoke.ipynb"
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let* ((view ein:nbview--view)
             (w2 (split-window))
             (cell (cadr (ein:view-cells view))))
        (with-selected-window w2
          (goto-char (car (ein:nbview--source-bounds view cell)))
          (insert "zz")
          (ein:nbview--post-command))
        (should (ein:nbview--check-invariants))
        (should (= 1 (with-temp-buffer
                       (insert (ein:view-cell-text view cell))
                       (count-matches "zz" (point-min) (point-max)))))
        (should (= 1 (cl-count-if (lambda (o) (overlay-get o 'ein-nbview-selection))
                                  (overlays-in (point-min) (point-max)))))
        (should (eq cell (oref view selected)))))))

;; (i)
(ert-deftest ein:nbview-layout-empty-notebook ()
  (ein:testing-with-nbview "empty.ipynb"
    (should (ein:nbview--check-invariants))
    (should-not (ein:view-cells ein:nbview--view))
    (should (text-property-any (point-min) (point-max)
                               'ein-nbview-part 'placeholder))
    (should (equal ein:nbview-placeholder-text
                   (get-text-property (point-min) 'display)))
    (let ((cell (ein:nbview-insert-cell-below)))
      (should (equal (list cell) (ein:view-cells ein:nbview--view)))
      (should-not (text-property-any (point-min) (point-max)
                                     'ein-nbview-part 'placeholder))
      (should (ein:nbview--check-invariants))
      (insert "1")
      (should (equal "1" (ein:view-cell-text ein:nbview--view cell)))
      (ein:nbview-delete-cell)
      (should (text-property-any (point-min) (point-max)
                                 'ein-nbview-part 'placeholder))
      (should (ein:nbview--check-invariants)))))

(ert-deftest ein:nbview-layout-empty-notebook-tangible ()
  "The cursor can rest on the placeholder of an empty notebook;
otherwise `cursor-intangible-mode' signals on every redisplay."
  (ein:testing-with-nbview "empty.ipynb"
    (should-not (ein:view-cells ein:nbview--view))
    (should (text-property-not-all (point-min) (point-max) 'cursor-intangible t))))

(ert-deftest ein:nbview-layout-display-updates-silent ()
  "Prompt and output re-renders neither modify the buffer nor touch undo."
  (ein:testing-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (code (cadr (ein:view-cells view))))
      (setq buffer-undo-list nil)
      (setf (slot-value code 'input-prompt-number) 7)
      (ein:view-cell-status-changed view code)
      (setf (slot-value code 'outputs)
            (list (list :output_type "stream" :name "stdout" :text "hello\n")))
      (ein:view-cell-outputs-changed view code)
      (should-not (buffer-modified-p))
      (should-not buffer-undo-list)
      (let ((h (ein:nbview--header-pos view code)))
        (should (string-match-p "\\[7\\]" (get-text-property h 'display)))
        (should (string-match-p "hello"
                                (ein:nbview--footer-rendered view code)))))))

(provide 'test-ein-nbview-layout)
;;; test-ein-nbview-layout.el ends here
