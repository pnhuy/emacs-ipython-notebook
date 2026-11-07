;;; test-ein-nbview-output.el --- Inline output rendering -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-nbview-output.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-nbview-output.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-nbview-output.el.  If not, see
;; <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T138: `ein:nbview-render-output' (text, errors, MIME priority,
;; unknown MIME, render errors).  T139: SVG and HTML sanitizers, no
;; remote fetch.  T140: truncation, collapse, coalescing, display
;; updates, no undo entries.  T141: image scaling.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'dom)
(require 'ein-notebook)
(require 'ein-nbview)
(require 'ein-nbview-output)
(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)

(defconst ein:testing-out-png
  "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAE0lEQVR4nGP4z8DwnwGM/zMwAAAf7gP9NRsAMwAAAABJRU5ErkJggg=="
  "A 2×2 PNG, base64.")

(defun ein:testing-out-render (output &rest context)
  "Render OUTPUT with CONTEXT (default: a graphic 1000 px window)."
  (ein:nbview-render-output
   output (append context (list :graphic t :window-width 1000))))

(defun ein:testing-out-images (string)
  "The image descriptors in STRING's `display' properties."
  (let (images (pos 0))
    (while (< pos (length string))
      (let ((d (get-text-property pos 'display string)))
        (when (eq (car-safe d) 'image) (cl-pushnew d images :test #'eq)))
      (setq pos (or (next-single-property-change pos 'display string) (length string))))
    (nreverse images)))

(defun ein:testing-out-faces (string pos)
  (ensure-list (get-text-property pos 'face string)))

;;; T138 Text and errors

(ert-deftest ein:nbview-output-stream ()
  (let ((s (ein:testing-out-render '(:output_type "stream" :name "stdout" :text "hello\n"))))
    (should (equal "hello\n" (substring-no-properties s))))
  (let ((s (ein:testing-out-render '(:output_type "stream" :name "stderr" :text "oops\n"))))
    (should (equal "oops\n" (substring-no-properties s)))
    (should (memq 'ein:nbview-stderr-face (ein:testing-out-faces s 0))))
  (let ((s (ein:testing-out-render '(:output_type "stream" :name "stdout"
                                                  :text "\e[31mred\e[0m plain"))))
    (should (equal "red plain" (substring-no-properties s)))
    (should-not (string-match-p "\e" s))
    (should (cl-some (lambda (f) (and (consp f) (plist-get f :foreground)))
                     (ein:testing-out-faces s 0))))
  (should (equal "b" (substring-no-properties
                      (ein:testing-out-render '(:output_type "stream" :name "stdout"
                                                             :text "a\rb")))))
  (should (equal "done 100%\n"
                 (substring-no-properties
                  (ein:testing-out-render
                   '(:output_type "stream" :name "stdout"
                                  :text "done  10%\rdone 100%\n"))))))

(ert-deftest ein:nbview-output-error ()
  (let ((s (ein:testing-out-render
            '(:output_type "error" :ename "ZeroDivisionError" :evalue "division by zero"
                           :traceback ["\e[31mTraceback\e[0m" "line 1"]))))
    (should (string-match-p "\\`ZeroDivisionError: division by zero\n" s))
    (should (string-match-p "Traceback\nline 1" s))
    (should-not (string-match-p "\e" s))
    (should (memq 'ein:nbview-error-face
                  (ein:testing-out-faces s (string-match "line 1" s))))))

(ert-deftest ein:nbview-output-mime-priority ()
  (let ((out `(:output_type "display_data"
                            :data (:text/plain "<Figure>" :image/png ,ein:testing-out-png)
                            :metadata nil)))
    (should (ein:testing-out-images (ein:testing-out-render out)))
    (let ((s (ein:nbview-render-output out '(:graphic nil :window-width 1000))))
      (should (equal "<Figure>" (string-trim (substring-no-properties s))))
      (should-not (ein:testing-out-images s)))
    (let ((ein:nbview-mime-priority '("text/plain" "image/png")))
      (should (equal "<Figure>" (string-trim (substring-no-properties
                                              (ein:testing-out-render out))))))
    ;; Inline images off: text is preferred.
    (let ((ein:nbview-inline-images nil))
      (should-not (ein:testing-out-images (ein:testing-out-render out)))))
  ;; Only an image on a terminal: a placeholder with its size.
  (let ((s (ein:nbview-render-output
            `(:output_type "display_data" :data (:image/png ,ein:testing-out-png))
            '(:graphic nil))))
    (should (string-match-p "\\[image/png 2×2\\]" s)))
  ;; execute_result: text/plain.
  (should (equal "42" (string-trim (substring-no-properties
                                    (ein:testing-out-render
                                     '(:output_type "execute_result" :execution_count 1
                                                    :data (:text/plain "42"))))))))

(ert-deftest ein:nbview-output-unknown-mime ()
  (let* ((s (ein:testing-out-render
             '(:output_type "display_data"
                            :data (:application/vnd.jupyter.widget-view+json
                                   (:model_id "abc" :version_major 2))))))
    (should (string-match-p
             "\\`\\[unsupported output: application/vnd\\.jupyter\\.widget-view\\+json, [0-9]+ bytes"
             s)))
  ;; The serialization of such a cell is unchanged.
  (let ((ein:notebook-view 'cells)
        (file (ein:testing-fixture "widget-mime.ipynb")))
    (ein:testing-with-notebook-file file
      (should (ein:nbview--check-invariants))
      (should (ein:testing-json-semantic-equal
               (with-temp-buffer (insert-file-contents file) (buffer-string))
               (ein:json-encode-notebook (ein:notebook-to-json ein:%notebook%)))))))

(ert-deftest ein:nbview-output-render-error ()
  (cl-letf (((symbol-function 'ein:nbview--render-mime)
             (lambda (&rest _) (error "Boom"))))
    (let ((s (ein:testing-out-render '(:output_type "display_data"
                                                    :data (:text/plain "x")))))
      (should (string-match-p "\\[render error: text/plain" s)))))

;;; T139 Sanitizers

(defun ein:testing-out-svg (svg)
  (ein:nbview--sanitize-svg svg))

(ert-deftest ein:nbview-output-sanitize-svg ()
  (skip-unless (libxml-available-p))
  (let ((s (ein:testing-out-svg
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" onload=\"alert(1)\">
<script>alert(2)</script>
<foreignObject><div>x</div></foreignObject>
<defs><circle id=\"c\" r=\"3\"/></defs>
<use href=\"#c\"/>
<image xlink:href=\"http://evil.example/x.png\"/>
<image href=\"data:image/png;base64,AAAA\"/>
<rect width=\"10\" height=\"10\" onclick=\"alert(3)\"/>
</svg>")))
    (should-not (string-match-p "<script" s))
    (should-not (string-match-p "alert" s))
    (should-not (string-match-p "foreignObject" s))
    (should-not (string-match-p "onload\\|onclick" s))
    (should-not (string-match-p "evil\\.example" s))
    (should (string-match-p "href=\"#c\"" s))
    (should (string-match-p "data:image/png" s))
    (should (string-match-p "<rect" s))))

(ert-deftest ein:nbview-output-sanitize-html ()
  (skip-unless (libxml-available-p))
  (let* ((dom (with-temp-buffer
                (insert "<div onclick=\"x()\"><script>bad()</script><style>p{}</style>"
                        "<iframe src=\"http://x\"></iframe><object></object><embed>"
                        "<p onmouseover=\"y()\">ok</p></div>")
                (libxml-parse-html-region (point-min) (point-max))))
         (clean (ein:nbview--sanitize-html-dom dom))
         (text (with-temp-buffer (dom-print clean) (buffer-string))))
    (dolist (tag '("script" "style" "iframe" "object" "embed"))
      (should-not (dom-by-tag clean (intern tag))))
    (should-not (string-match-p "onclick\\|onmouseover\\|bad()" text))
    (should (string-match-p "ok" text))))

(ert-deftest ein:nbview-output-html-no-fetch ()
  (skip-unless (libxml-available-p))
  (cl-letf (((symbol-function 'url-retrieve)
             (lambda (&rest _) (ert-fail "url-retrieve called")))
            ((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _) (ert-fail "url-retrieve-synchronously called")))
            ((symbol-function 'url-queue-retrieve)
             (lambda (&rest _) (ert-fail "url-queue-retrieve called"))))
    (let ((s (ein:testing-out-render
              '(:output_type "display_data"
                             :data (:text/html "<p>before<img src=\"http://example.com/x.png\" alt=\"pic\">after</p>")))))
      (should (string-match-p "before" s))
      (should (string-match-p "after" s)))))

(ert-deftest ein:nbview-output-html-table ()
  (skip-unless (libxml-available-p))
  (let* ((html "<div><table border=\"1\" class=\"dataframe\">
<thead><tr style=\"text-align: right;\"><th></th><th>a</th><th>b</th></tr></thead>
<tbody><tr><th>0</th><td>1</td><td>x</td></tr>
<tr><th>1</th><td>22</td><td>yy</td></tr></tbody></table></div>")
         (s (substring-no-properties
             (ein:testing-out-render `(:output_type "execute_result"
                                                    :data (:text/html ,html :text/plain "df"))))))
    (dolist (v '("a" "b" "22" "yy"))
      (should (string-match-p (regexp-quote v) s)))
    (should-not (string-match-p "<td>" s))
    ;; Rows are on separate lines.
    (should (< (string-match "1 *.*x" s) (string-match "22" s)))))

;;; T141 Image scaling

(ert-deftest ein:nbview-output-image-scaling ()
  (let ((ein:nbview-image-max-width 0.5)
        (ein:nbview-image-max-height 600)
        (out `(:output_type "display_data" :data (:image/png ,ein:testing-out-png))))
    (let ((img (car (ein:testing-out-images
                     (ein:nbview-render-output out '(:graphic t :window-width 1000))))))
      (should img)
      (should (= 500 (image-property img :max-width)))
      (should (= 600 (image-property img :max-height))))
    (let ((ein:nbview-image-max-width 300))
      (should (= 300 (image-property
                      (car (ein:testing-out-images
                            (ein:nbview-render-output out '(:graphic t :window-width 1000))))
                      :max-width))))
    ;; Output metadata width is honoured, bounded by the maximum.
    (let ((img (car (ein:testing-out-images
                     (ein:nbview-render-output
                      (append out '(:metadata (:image/png (:width 120 :height 80))))
                      '(:graphic t :window-width 1000))))))
      (should (= 120 (image-property img :width))))))

;;; T140 Behaviour in the cells view

(defmacro ein:testing-out-with-nbview (fixture &rest body)
  (declare (indent 1) (debug t))
  `(let ((ein:notebook-view 'cells))
     (ein:testing-with-notebook-file (ein:testing-fixture ,fixture)
       ,@body)))

(defun ein:testing-out-code-cell ()
  (cl-find-if #'ein:codecell-p (ein:view-cells ein:nbview--view)))

(defun ein:testing-out-footer (cell)
  (substring-no-properties (ein:nbview--footer-rendered ein:nbview--view cell)))

(ert-deftest ein:nbview-output-footer-overlay ()
  "Outputs live in an overlay string: images in them can display."
  (ein:testing-out-with-nbview "multimime.ipynb"
    (let* ((view ein:nbview--view)
           (cell (ein:testing-out-code-cell))
           (f (ein:nbview--footer-pos (ein:nbview--header-pos view cell))))
      (should-not (get-text-property f 'display))
      (should (ein:nbview--footer-rendered view cell))
      (should (eq cell (get-text-property 0 'ein-nbview-cell
                                          (ein:nbview--footer-rendered view cell))))
      (when (display-images-p)
        (should (ein:testing-out-images (ein:nbview--footer-rendered view cell))))
      ;; Typing at the end of the source stays outside the overlay.
      (ein:nbview-select-cell cell)
      (goto-char f)
      (let ((inhibit-read-only nil)) (insert "z"))
      (should (equal (concat "show()" "z") (ein:view-cell-text view cell)))
      (should (= (1+ f) (ein:nbview--footer-pos (ein:nbview--header-pos view cell))))
      (should (ein:nbview--footer-rendered view cell)))))

(ert-deftest ein:nbview-output-footer-lines-own-prefix ()
  "Every footer line starts inside the overlay string, so it takes the
cell's bar, also for the last cell (regression: the first output line
took the prefix of the text after the footer, none at the end)."
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cell (car (last (ein:view-cells view))))
           (f (ein:nbview--footer-pos (ein:nbview--header-pos view cell)))
           (ov (ein:nbview--footer-overlay view cell))
           (s (overlay-get ov 'before-string)))
      (should (= f (1- (point-max))))
      (should-not (overlay-get ov 'after-string))
      (should (string-prefix-p " \n" s))
      (should-not (string-suffix-p "\n" s))
      ;; Point at the end of the source is drawn there, not after the outputs.
      (should (get-text-property 0 'cursor s))
      (should-not (get-text-property 1 'cursor s))
      (should (cl-every (lambda (i) (get-text-property i 'line-prefix s))
                        (number-sequence 0 (1- (length s)))))
      (ein:nbview-select-cell cell)
      (should (eq (ein:nbview--selection-face)
                  (get-text-property 0 'face (get-text-property
                                              1 'line-prefix
                                              (overlay-get ov 'before-string))))))))

(ert-deftest ein:nbview-output-truncation ()
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cell (ein:testing-out-code-cell))
           (ein:nbview-output-max-lines 10))
      (setf (slot-value cell 'outputs)
            (list (list :output_type "stream" :name "stdout"
                        :text (mapconcat (lambda (i) (format "line%d\n" i))
                                         (number-sequence 1 50) ""))))
      (ein:nbview--render-footer view cell)
      (let ((s (ein:testing-out-footer cell)))
        (should (string-match-p "line10\n" s))
        (should-not (string-match-p "line11\n" s))
        (should (string-match-p "40 more lines" s)))
      (ein:nbview-select-cell cell)
      (ein:nbview-toggle-output-truncation)
      (let ((s (ein:testing-out-footer cell)))
        (should (string-match-p "line50\n" s))
        (should-not (string-match-p "more lines" s)))
      (ein:nbview-toggle-output-truncation)
      (should-not (string-match-p "line11\n" (ein:testing-out-footer cell))))))

(ert-deftest ein:nbview-output-collapse ()
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cell (ein:testing-out-code-cell)))
      (setf (slot-value cell 'outputs)
            (list (list :output_type "stream" :name "stdout" :text "visible\n")))
      (ein:nbview--render-footer view cell)
      (ein:nbview-select-cell cell)
      (setq buffer-undo-list nil)
      (ein:nbview-toggle-output)
      (should (slot-value cell 'collapsed))
      (should-not (string-match-p "visible" (ein:testing-out-footer cell)))
      (should (string-match-p "outputs hidden" (ein:testing-out-footer cell)))
      (let* ((json (ein:cell-to-nb4-json cell 0))
             (md (cdr (assq 'metadata json))))
        (should (eq t (plist-get (plist-get md :jupyter) :outputs_hidden)))
        ;; `collapsed' was absent from the file: not added.
        (should-not (plist-member md :collapsed)))
      (ein:nbview-toggle-output)
      (should-not (slot-value cell 'collapsed))
      (should (string-match-p "visible" (ein:testing-out-footer cell)))
      (should-not buffer-undo-list)))
  ;; `collapsed' present in the file is updated too.
  (let ((cell (ein:cell-from-json
               '(:cell_type "code" :source "x" :outputs []
                            :metadata (:collapsed :json-false)))))
    (setf (slot-value cell 'raw) '(:cell_type "code" :metadata (:collapsed :json-false)))
    (setf (slot-value cell 'collapsed) t)
    (let ((md (ein:cell--metadata-to-json cell)))
      (should (eq t (plist-get md :collapsed)))
      (should (eq t (plist-get (plist-get md :jupyter) :outputs_hidden))))))

(ert-deftest ein:nbview-output-toggle-input ()
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cell (ein:testing-out-code-cell))
           (text (ein:view-cell-text view cell)))
      (ein:nbview-select-cell cell)
      (ein:nbview-toggle-input)
      (let ((b (ein:nbview--source-bounds view cell)))
        (should (invisible-p (car b))))
      (should (equal text (ein:view-cell-text view cell)))
      (should-not (buffer-modified-p))
      (ein:nbview-toggle-input)
      (should-not (invisible-p (car (ein:nbview--source-bounds view cell)))))))

(ert-deftest ein:nbview-output-clear ()
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cells (cl-remove-if-not #'ein:codecell-p (ein:view-cells view))))
      (dolist (c cells)
        (setf (slot-value c 'outputs)
              (list (list :output_type "stream" :name "stdout" :text "out\n")))
        (ein:nbview--render-footer view c))
      (ein:nbview-select-cell (car cells))
      (ein:nbview-clear-output)
      (should-not (slot-value (car cells) 'outputs))
      (should-not (string-match-p "out" (ein:testing-out-footer (car cells))))
      (ein:nbview-clear-all-output)
      (dolist (c cells)
        (should-not (slot-value c 'outputs))))))

(ert-deftest ein:nbview-output-coalescing ()
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((view ein:nbview--view)
           (cell (ein:testing-out-code-cell))
           (renders 0))
      (advice-add 'ein:nbview--render-footer :before
                  (lambda (&rest _) (cl-incf renders)) '((name . count)))
      (unwind-protect
          (progn
            (setq buffer-undo-list nil)
            (setf (slot-value cell 'outputs) nil)
            (dotimes (i 100)
              (ein:cell-append-output cell (list :output_type "stream" :name "stdout"
                                                 :text (format "%d\n" i))))
            (with-timeout (2 (ert-fail "No trailing render"))
              (while (not (string-match-p "99\n" (ein:testing-out-footer cell)))
                (accept-process-output nil 0.02)))
            (accept-process-output nil 0.15)
            (should (<= renders 3))
            (should (string-match-p "\\`0\n1\n" (ein:testing-out-footer cell)))
            (should-not buffer-undo-list))
        (advice-remove 'ein:nbview--render-footer 'count)))))

(ert-deftest ein:nbview-output-display-updates ()
  (ein:testing-out-with-nbview "smoke.ipynb"
    (let* ((cell (ein:testing-out-code-cell)))
      (setq buffer-undo-list nil)
      (ein:cell-clear-output cell t t t)
      (ein:cell--handle-output cell "display_data"
                               '(:data (:text/plain "first") :metadata nil
                                       :transient (:display_id "d1"))
                               nil)
      (ein:cell--handle-output cell "stream" '(:name "stdout" :text "between\n") nil)
      (ein:cell--handle-output cell "update_display_data"
                               '(:data (:text/plain "second") :metadata nil
                                       :transient (:display_id "d1"))
                               nil)
      (should (= 2 (length (slot-value cell 'outputs))))
      (should (equal "second" (plist-get (plist-get (car (slot-value cell 'outputs)) :data)
                                         :text/plain)))
      (should-not (plist-member (car (slot-value cell 'outputs)) :transient))
      ;; clear_output with wait: cleared only when the next output arrives.
      (ein:cell--handle-clear-output cell '(:wait t) nil)
      (should (= 2 (length (slot-value cell 'outputs))))
      (ein:cell--handle-output cell "stream" '(:name "stdout" :text "after\n") nil)
      (should (equal '("after\n")
                     (mapcar (lambda (o) (plist-get o :text)) (slot-value cell 'outputs))))
      (ein:cell--handle-clear-output cell '(:wait :json-false) nil)
      (should-not (slot-value cell 'outputs))
      (should-not buffer-undo-list))))

(ert-deftest ein:nbview-output-no-undo-entries ()
  (ein:testing-out-with-nbview "multimime.ipynb"
    (let* ((view ein:nbview--view)
           (cell (ein:testing-out-code-cell)))
      (setq buffer-undo-list nil)
      (ein:nbview--assert-no-undo-entries
       (lambda ()
         (ein:nbview--render-footer view cell)
         (ein:cell-append-output cell '(:output_type "stream" :name "stdout" :text "x\n"))
         (ein:nbview-select-cell cell)
         (ein:nbview-toggle-output)
         (ein:nbview-toggle-output)
         (ein:nbview-toggle-output-truncation)
         (ein:nbview-clear-output)))
      (should-not (buffer-modified-p)))))

(provide 'test-ein-nbview-output)

;;; test-ein-nbview-output.el ends here
