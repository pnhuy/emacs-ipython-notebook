;;; ein-nbview-output.el --- Output rendering for the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-nbview-output.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; ein-nbview-output.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-nbview-output.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Pure renderers from nbformat outputs to propertized strings
;; (contracts/renderers.md).  The cells view shows the strings below a
;; code cell, in an overlay string, so outputs are never buffer text.
;;
;; A rich output is shown in the first MIME type of
;; `ein:nbview-mime-priority' that it has and this display can show:
;; images inline in graphic frames, HTML through shr after the DOM is
;; sanitized, LaTeX through ein-latex.el, Markdown through the Markdown
;; preview renderer, and text with its ANSI colours and carriage
;; returns applied.  Other MIME types show a placeholder; their data
;; stays in the notebook unchanged.
;;
;; Safety: nothing here runs scripts or fetches remote resources.  The
;; HTML and SVG sanitizers drop scripts, event handler attributes,
;; embedded documents and every reference that is not local to the
;; output (`#id' or `data:'), unless `ein:nbview-fetch-remote-images'
;; allows remote images.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ansi-color)
(require 'dom)
(require 'button)
(require 'ein-log)
(require 'ein-utils)
(require 'ein-latex)
(require 'ein-nbview-markdown)

(defvar shr-width)
(defvar shr-max-width)
(defvar shr-use-fonts)
(defvar shr-use-colors)
(defvar shr-inhibit-images)
(defvar shr-blocked-images)
(declare-function shr-insert-document "shr")

(defcustom ein:nbview-mime-priority
  '("image/png" "image/jpeg" "image/svg+xml" "text/html" "text/latex"
    "text/markdown" "text/plain")
  "MIME types of rich outputs, most preferred first.
An output is shown in the first of these it has that the display can
show (images need a graphic frame and `ein:nbview-inline-images').
Types not listed show a placeholder; their data is kept."
  :type '(repeat string)
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-inline-images t
  "Non-nil: show image outputs inline in graphic frames.
When nil, or in a terminal, a text representation is preferred and a
placeholder shows images that have none."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-output-max-lines 200
  "Lines of outputs a cell shows before they are truncated.
The rest is behind an expand button (also
`ein:nbview-toggle-output-truncation').  Nil means no limit."
  :type '(choice (const :tag "No limit" nil) natnum)
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

;;; Helpers

(defun ein:nbview-output--string (value)
  "VALUE, a string or a sequence of strings (nbformat), as one string."
  (cond ((stringp value) value)
        ((null value) "")
        ((sequencep value) (mapconcat (lambda (s) (format "%s" s)) value ""))
        (t (format "%s" value))))

(defun ein:nbview-output--ansi (string)
  "STRING with its ANSI escapes turned into faces."
  (let* ((ansi-color-context nil)
         (s (ansi-color-apply string))
         (pos 0))
    ;; `ansi-color-apply' uses `font-lock-face'; the view has no
    ;; font-lock on overlay strings, so use `face'.
    (while (< pos (length s))
      (let ((next (next-single-property-change pos 'font-lock-face s (length s)))
            (face (get-text-property pos 'font-lock-face s)))
        (when face
          (remove-text-properties pos next '(font-lock-face nil) s)
          (add-face-text-property pos next face t s))
        (setq pos next)))
    s))

(defun ein:nbview-output--text (string face)
  "STRING as terminal text (ANSI colours, carriage returns) in FACE."
  (let ((s (ein:output-apply-carriage-returns
            (ein:nbview-output--ansi (ein:nbview-output--string string)))))
    (when face (add-face-text-property 0 (length s) face t s))
    s))

(defun ein:nbview-output--mime-key (mime)
  "Return the plist keyword for the MIME type."
  (intern (concat ":" mime)))

(defun ein:nbview-output--data-mimes (data)
  "The MIME types of the bundle DATA, in order."
  (cl-loop for (k _v) on data by #'cddr
           when (keywordp k) collect (substring (symbol-name k) 1)))

(defun ein:nbview-output--image-type (mime)
  "Return the Emacs image type for MIME, or nil."
  (pcase mime
    ("image/png" 'png) ("image/jpeg" 'jpeg) ("image/gif" 'gif)
    ("image/svg+xml" 'svg)))

(defun ein:nbview-output--usable-p (mime context)
  "Non-nil when MIME can be shown in CONTEXT."
  (let ((type (ein:nbview-output--image-type mime)))
    (cond
     (type (and ein:nbview-inline-images (plist-get context :graphic)
                (image-type-available-p type)
                (or (not (eq type 'svg)) (libxml-available-p))))
     ((equal mime "text/html") (libxml-available-p))
     (t t))))

(defun ein:nbview-output-choose-mime (data context)
  "The MIME type in which to show the bundle DATA in CONTEXT, or nil.
Nil means DATA has no type of `ein:nbview-mime-priority'."
  (let ((mimes (ein:nbview-output--data-mimes data)))
    (or (cl-find-if (lambda (m) (and (member m mimes)
                                     (ein:nbview-output--usable-p m context)))
                    ein:nbview-mime-priority)
        (cl-find-if (lambda (m) (member m mimes)) ein:nbview-mime-priority))))

;;; Images

(defun ein:nbview-output--max-size (context)
  "Maximum (WIDTH . HEIGHT) in pixels of images in CONTEXT."
  (let ((w (or (plist-get context :window-width) 800)))
    (cons (if (floatp ein:nbview-image-max-width)
              (max 16 (round (* ein:nbview-image-max-width w)))
            ein:nbview-image-max-width)
          ein:nbview-image-max-height)))

(defun ein:nbview-output--png-size (data)
  "(WIDTH . HEIGHT) from the header of the PNG DATA, or nil."
  (when (and (>= (length data) 24)
             (string-prefix-p "\211PNG" data))
    (cl-flet ((u32 (i) (+ (ash (aref data i) 24) (ash (aref data (+ i 1)) 16)
                          (ash (aref data (+ i 2)) 8) (aref data (+ i 3)))))
      (cons (u32 16) (u32 20)))))

(defun ein:nbview-output--image-data (mime value)
  "The bytes of the image VALUE of MIME, or nil."
  (let ((s (ein:nbview-output--string value)))
    (if (equal mime "image/svg+xml")
        (ein:nbview-sanitize-svg s)
      (ignore-errors
        (base64-decode-string (replace-regexp-in-string "[ \t\n\r]" "" s))))))

(defun ein:nbview-output--image (mime value metadata context)
  "The image VALUE of MIME as a string: inline, or a placeholder."
  (let* ((type (ein:nbview-output--image-type mime))
         (data (ein:nbview-output--image-data mime value))
         (meta (plist-get metadata (ein:nbview-output--mime-key mime)))
         (mw (plist-get meta :width))
         (mh (plist-get meta :height))
         (size (or (and (numberp mw) (numberp mh) (cons mw mh))
                   (and (eq type 'png) data (ein:nbview-output--png-size data))))
         (label (if size (format "[%s %d×%d]" mime (car size) (cdr size))
                  (format "[%s]" mime))))
    (if (and data (ein:nbview-output--usable-p mime context))
        (let* ((max (ein:nbview-output--max-size context))
               (props (append (list :max-width (car max) :max-height (cdr max)
                                    :scale (ein:nbview-image-scale)
                                    :ascent 'center)
                              (and (numberp mw) (list :width (min mw (car max))))
                              (and (numberp mh) (not (numberp mw))
                                   (list :height (min mh (cdr max))))))
               (image (apply #'create-image data type t props)))
          (propertize label 'display image 'help-echo mime))
      (propertize label 'face 'shadow))))

;;; SVG and HTML sanitizers

(defconst ein:nbview-output--unsafe-tags
  '(script style iframe frame frameset object embed applet link meta base
           form input button textarea select foreignObject foreignobject
           audio video source track noscript template portal)
  "Elements removed with their contents.")

(defun ein:nbview-output--local-ref-p (value)
  "Non-nil when the reference VALUE stays inside the output."
  (let ((v (string-trim (or value ""))))
    (or (string-prefix-p "#" v)
        (string-prefix-p "data:" (downcase v)))))

(defun ein:nbview-output--safe-css-p (value)
  "Non-nil when the CSS VALUE references nothing outside the output."
  (not (string-match-p
        "@import\\|expression\\s-*(\\|url\\s-*(\\s-*['\"]?\\s-*\\(?:[a-zA-Z][-a-zA-Z0-9+.]*:\\)?[^d'\"\\s-]"
        (or value ""))))

(defun ein:nbview-output--clean-attrs (node allow-remote-img)
  "Remove the unsafe attributes of NODE in place.
ALLOW-REMOTE-IMG non-nil keeps http(s) `src' of `img' elements."
  (let ((tag (dom-tag node)))
    (setcar (cdr node)
          (cl-remove-if
           (lambda (attr)
             (let ((name (downcase (symbol-name (car attr))))
                   (value (format "%s" (cdr attr))))
               (cond
                ((string-prefix-p "on" name) t)
                ((equal name "style") (not (ein:nbview-output--safe-css-p value)))
                ((and (eq tag 'a) (equal name "href"))
                 (string-match-p "\\`\\s-*\\(?:javascript\\|vbscript\\|data\\):" (downcase value)))
                ((member name '("href" "xlink:href" "src" "srcset" "poster" "background"
                                "action" "formaction" "data" "codebase" "dynsrc" "lowsrc"))
                 (not (or (ein:nbview-output--local-ref-p value)
                          (and allow-remote-img (eq tag 'img) (equal name "src")
                               (string-match-p "\\`https?://" value)))))
                (t nil))))
           (dom-attributes node)))))

(defun ein:nbview-output--clean (node allow-remote-img)
  "NODE without unsafe elements and attributes, or nil if unsafe.
Strings are kept.  ALLOW-REMOTE-IMG is as for
`ein:nbview-output--clean-attrs'."
  (cond
   ((stringp node) node)
   ((not (consp node)) nil)
   ((memq (dom-tag node) '(comment top)) (and (eq (dom-tag node) 'top)
                                              (ein:nbview-output--clean-children
                                               node allow-remote-img)))
   ((memq (dom-tag node) ein:nbview-output--unsafe-tags) nil)
   ((and (eq (dom-tag node) 'img)
         (let ((src (dom-attr node 'src)))
           (not (or (ein:nbview-output--local-ref-p src)
                    (and allow-remote-img src (string-match-p "\\`https?://" src))))))
    ;; An image that cannot be shown safely: keep its description.
    (let ((alt (dom-attr node 'alt)))
      (format "[image%s]" (if (and alt (not (string-empty-p alt))) (concat " " alt) ""))))
   (t (ein:nbview-output--clean-children node allow-remote-img))))

(defun ein:nbview-output--clean-children (node allow-remote-img)
  "Return a sanitized copy of NODE and its children.
ALLOW-REMOTE-IMG non-nil keeps remote image references."
  (let ((copy (copy-sequence node)))
    (setcar (cdr copy) (copy-tree (dom-attributes node)))
    (ein:nbview-output--clean-attrs copy allow-remote-img)
    (setcdr (cdr copy)
            (delq nil (mapcar (lambda (c) (ein:nbview-output--clean c allow-remote-img))
                              (dom-children node))))
    copy))

(defun ein:nbview--sanitize-html-dom (dom)
  "Return a sanitized copy of the HTML DOM.
The copy has no scripts, styles, embedded documents, event handler
attributes or remote references.
Remote images are kept only when `ein:nbview-fetch-remote-images' is
non-nil."
  (or (ein:nbview-output--clean dom ein:nbview-fetch-remote-images)
      (dom-node 'div)))

(defun ein:nbview-sanitize-svg (svg)
  "The SVG document SVG (a string) made safe to display, or nil.
Scripts, `foreignObject', event handler attributes and references
outside the document are removed.  The result is UTF-8 encoded.  Nil
means SVG cannot be parsed, or libxml2 is not available."
  (when (libxml-available-p)
    (condition-case err
        (let* ((text (if (multibyte-string-p svg) svg (decode-coding-string svg 'utf-8)))
               (dom (with-temp-buffer
                      (insert text)
                      (libxml-parse-xml-region (point-min) (point-max))))
               (clean (and (consp dom) (ein:nbview-output--clean dom nil))))
          (when (and (consp clean) (eq (dom-tag clean) 'svg))
            (unless (dom-attr clean 'xmlns)
              (dom-set-attribute clean 'xmlns "http://www.w3.org/2000/svg"))
            (when (and (not (dom-attr clean 'xmlns:xlink))
                       (string-match-p "xlink:" (format "%S" clean)))
              (dom-set-attribute clean 'xmlns:xlink "http://www.w3.org/1999/xlink"))
            (encode-coding-string
             (with-temp-buffer (dom-print clean nil t) (buffer-string))
             'utf-8)))
      (error (ein:log 'warn "SVG sanitizer: %s" (error-message-string err))
             nil))))

(defalias 'ein:nbview--sanitize-svg #'ein:nbview-sanitize-svg)

(defun ein:nbview-output--html (html context)
  "Return HTML rendered as text by shr, after sanitizing.
CONTEXT gives the window width and whether images may be shown."
  (require 'shr)
  (let* ((dom (with-temp-buffer
                (insert html)
                (libxml-parse-html-region (point-min) (point-max))))
         (clean (ein:nbview--sanitize-html-dom dom))
         (cols (max 20 (or (plist-get context :window-cols) 80))))
    (with-temp-buffer
      (let ((shr-width cols)
            (shr-max-width cols)
            (shr-use-fonts nil)
            (shr-use-colors nil)
            (shr-inhibit-images (not (and (plist-get context :graphic)
                                          ein:nbview-inline-images)))
            (shr-blocked-images (unless ein:nbview-fetch-remote-images
                                  "\\`\\(?:https?\\|ftp\\|file\\):")))
        (shr-insert-document clean))
      (string-trim (buffer-string) "\n+" "[ \t\n]+"))))

;;; LaTeX and Markdown

(defun ein:nbview-output--strip-math (latex)
  "LATEX without its outer math delimiters."
  (let ((s (string-trim latex)))
    (cond
     ((string-match "\\`\\$\\$\\(\\(?:.\\|\n\\)*\\)\\$\\$\\'" s) (match-string 1 s))
     ((string-match "\\`\\$\\(\\(?:.\\|\n\\)*\\)\\$\\'" s) (match-string 1 s))
     ((string-match "\\`\\\\\\[\\(\\(?:.\\|\n\\)*\\)\\\\\\]\\'" s) (match-string 1 s))
     (t s))))

(defun ein:nbview-output--latex (latex context)
  "Return LATEX rendered for the output CONTEXT."
  (ein:latex-render (ein:nbview-output--strip-math latex) t
                    (lambda (&rest _)
                      (when-let* ((f (plist-get context :on-update))) (funcall f)))
                    (plist-get context :cell)))

(defun ein:nbview-output--markdown (markdown context)
  "Return MARKDOWN rendered for the output CONTEXT."
  (ein:nbview-render-markdown
   markdown
   (list :graphic (plist-get context :graphic)
         :window-width (plist-get context :window-width)
         :notebook-dir (plist-get context :notebook-dir)
         :owner (plist-get context :cell)
         :refresh (plist-get context :on-update))))

;;; Entry points

(defun ein:nbview--render-mime (mime value output context)
  "VALUE of type MIME, from OUTPUT, rendered in CONTEXT."
  (pcase mime
    ((or "image/png" "image/jpeg" "image/gif" "image/svg+xml")
     (ein:nbview-output--image mime value (plist-get output :metadata) context))
    ("text/html" (ein:nbview-output--html (ein:nbview-output--string value) context))
    ("text/latex" (ein:nbview-output--latex (ein:nbview-output--string value) context))
    ("text/markdown" (ein:nbview-output--markdown (ein:nbview-output--string value) context))
    (_ (ein:nbview-output--text value 'ein:nbview-output-face))))

(defun ein:nbview-output--unsupported (data)
  "Return a placeholder line for the unsupported bundle DATA."
  (let* ((mime (car (ein:nbview-output--data-mimes data)))
         (value (plist-get data (ein:nbview-output--mime-key (or mime ""))))
         (bytes (string-bytes (if (stringp value) value
                                (or (ignore-errors (json-encode value)) "")))))
    (propertize (if mime
                    (format "[unsupported output: %s, %d bytes — C-c C-o to view raw]"
                            mime bytes)
                  "[empty output]")
                'face 'shadow)))

(defun ein:nbview-render-output (output context)
  "Render OUTPUT, an nbformat output plist, as a propertized string.
CONTEXT is a plist:
  :graphic       non-nil in a graphic frame
  :window-width  window body width in pixels, for image scaling
  :window-cols   window body width in columns, for HTML
  :notebook-dir  local directory of the notebook, for Markdown images
  :cell          the cell, which owns asynchronous LaTeX work
  :on-update     function called when an asynchronous part is ready
The result has no added trailing newline.  A renderer error shows a
placeholder and is logged; it is never signalled."
  (let ((type (plist-get output :output_type)))
    (pcase type
      ("stream"
       (ein:nbview-output--text (plist-get output :text)
                                (if (equal (or (plist-get output :name)
                                               (plist-get output :stream))
                                           "stderr")
                                    'ein:nbview-stderr-face
                                  'ein:nbview-output-face)))
      ((or "error" "pyerr")
       (let ((header (propertize (format "%s: %s"
                                         (or (plist-get output :ename) "Error")
                                         (or (plist-get output :evalue) ""))
                                 'face '(ein:nbview-error-face bold)))
             (tb (ein:nbview-output--text
                  (mapconcat (lambda (l) (format "%s" l))
                             (append (plist-get output :traceback) nil) "\n")
                  'ein:nbview-error-face)))
         (if (string-empty-p tb) header (concat header "\n" tb))))
      (_
       (let* ((data (or (plist-get output :data) output))
              (mime (ein:nbview-output-choose-mime data context)))
         (if (not mime)
             (ein:nbview-output--unsupported data)
           (condition-case err
               (ein:nbview--render-mime mime (plist-get data (ein:nbview-output--mime-key mime))
                                        output context)
             (error
              (ein:log 'warn "Rendering %s output failed: %s" mime (error-message-string err))
              (propertize (format "[render error: %s]" mime) 'face 'warning)))))))))

(defun ein:nbview-output--merge-streams (outputs)
  "OUTPUTS with consecutive stream outputs of one name joined.
Kernels send a stream message per write; joining them lets a carriage
return overwrite text of an earlier message.  OUTPUTS is not modified."
  (let (result)
    (dolist (o outputs)
      (let ((prev (car result)))
        (if (and prev
                 (equal (plist-get o :output_type) "stream")
                 (equal (plist-get prev :output_type) "stream")
                 (equal (plist-get o :name) (plist-get prev :name)))
            (setcar result (list :output_type "stream" :name (plist-get o :name)
                                 :text (concat (ein:nbview-output--string (plist-get prev :text))
                                               (ein:nbview-output--string (plist-get o :text)))))
          (push o result))))
    (nreverse result)))

(defun ein:nbview-render-outputs (outputs context)
  "Render the list OUTPUTS in CONTEXT; each ends with a newline."
  (mapconcat (lambda (o)
               (let ((s (ein:nbview-render-output o context)))
                 (if (string-suffix-p "\n" s) s (concat s "\n"))))
             (ein:nbview-output--merge-streams outputs) ""))

(defun ein:nbview-output-truncate (string max-lines expand)
  "STRING cut after MAX-LINES lines, with a button calling EXPAND.
Return STRING when it is short enough or MAX-LINES is nil."
  (let ((pos 0) (n 0))
    (while (and max-lines (< n max-lines)
                (setq pos (string-search "\n" string pos)))
      (setq pos (1+ pos) n (1+ n)))
    (if (or (null max-lines) (null pos) (>= pos (length string)))
        string
      (let ((rest (cl-count ?\n string :start pos)))
        (when (and (< pos (length string)) (not (string-suffix-p "\n" string)))
          (cl-incf rest))
        (concat (substring string 0 pos)
                (buttonize (format "… %d more lines (expand)" rest)
                           (lambda (_) (funcall expand))
                           nil "Show all outputs")
                "\n")))))

;;; Copying and inspecting outputs

(declare-function ein:nbview--cell-or-error "ein-nbview")

(defun ein:nbview-output--cell-outputs (cell)
  "CELL's outputs, nil for a cell without an outputs slot."
  (and (slot-exists-p cell 'outputs) (slot-value cell 'outputs)))

(defun ein:nbview-output--plain (output)
  "OUTPUT as plain text without colours, or nil when it has none."
  (let ((text
         (pcase (plist-get output :output_type)
           ("stream" (ein:nbview-output--string (plist-get output :text)))
           ((or "error" "pyerr")
            (concat (format "%s: %s\n" (or (plist-get output :ename) "Error")
                            (or (plist-get output :evalue) ""))
                    (mapconcat (lambda (l) (format "%s" l))
                               (append (plist-get output :traceback) nil) "\n")))
           (_ (when-let* ((v (plist-get (or (plist-get output :data) output)
                                        :text/plain)))
                (ein:nbview-output--string v))))))
    (when text
      (let ((s (ansi-color-filter-apply text)))
        (if (string-suffix-p "\n" s) s (concat s "\n"))))))

(defun ein:nbview-output-copy ()
  "Copy the plain-text outputs of the current cell to the kill ring."
  (interactive)
  (let* ((cell (ein:nbview--cell-or-error))
         (text (mapconcat #'identity
                          (delq nil (mapcar #'ein:nbview-output--plain
                                            (ein:nbview-output--cell-outputs cell)))
                          "")))
    (if (string-empty-p text)
        (user-error "No text output")
      (kill-new text)
      (message "Copied %d characters of output" (length text)))))

(defun ein:nbview-output--raw-value (value)
  "VALUE of a MIME bundle as a string; long data is abbreviated."
  (let ((s (cond ((stringp value) value)
                 ((and (sequencep value) (cl-every #'stringp value))
                  (mapconcat #'identity value ""))
                 (t (format "%S" value)))))
    (if (> (length s) 4000)
        (format "%s… [%d characters]" (substring s 0 200) (length s))
      s)))

(defun ein:nbview-output-view ()
  "Show every raw output of the current cell, MIME-labelled, read-only."
  (interactive)
  (let* ((cell (ein:nbview--cell-or-error))
         (outputs (ein:nbview-output--cell-outputs cell))
         (buffer (get-buffer-create (format "*ein outputs: %s*" (buffer-name)))))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (unless outputs (insert "No outputs.\n"))
        (cl-loop
         for o in outputs for i from 1 do
         (let ((type (plist-get o :output_type)))
           (insert (propertize (format "Output %d: %s\n" i type) 'face 'bold))
           (pcase type
             ("stream"
              (insert (format "[%s]\n" (or (plist-get o :name) "stdout"))
                      (ein:nbview-output--string (plist-get o :text))))
             ((or "error" "pyerr") (insert (ein:nbview-output--plain o)))
             (_
              (let ((data (or (plist-get o :data) '())))
                (cl-loop for (k v) on data by #'cddr do
                         (insert (propertize (format "[%s]\n" (substring (symbol-name k) 1))
                                             'face 'shadow)
                                 (ein:nbview-output--raw-value v) "\n")))))
           (unless (bolp) (insert "\n"))
           (insert "\n")))
        (goto-char (point-min))))
    (display-buffer buffer)
    buffer))

(defvar-keymap ein:nbview-output-map
  :doc "Commands on the current cell's outputs."
  :prefix 'ein:nbview-output-map
  "c" #'ein:nbview-output-copy
  "M-w" #'ein:nbview-output-copy
  "v" #'ein:nbview-output-view
  "C-o" #'ein:nbview-output-view)

(provide 'ein-nbview-output)

;;; ein-nbview-output.el ends here
