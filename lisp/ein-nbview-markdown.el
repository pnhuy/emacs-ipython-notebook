;;; ein-nbview-markdown.el --- Markdown previews for the cells view -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-nbview-markdown.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; ein-nbview-markdown.el is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-nbview-markdown.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A small, pure renderer from Markdown source to a propertized string
;; (contracts/renderers.md).  The cells view shows the string over the
;; source of an inactive Markdown cell with a `display' overlay, so the
;; buffer text, and the notebook, keep the source unchanged.
;;
;; Supported: ATX and setext headings, emphasis, strong, strikethrough,
;; inline code, links and autolinks (as buttons, never followed by
;; themselves), bullet, ordered and task lists, block quotes, rules,
;; fenced code (fontified by the language's major mode), GFM tables,
;; images (attachments, data: URIs, files under the notebook
;; directory) and LaTeX math (see ein-latex.el).  Anything else,
;; including inline HTML, is shown as its literal text.
;;
;; Remote images are fetched only when `ein:nbview-fetch-remote-images'
;; is non-nil; otherwise they show as a link placeholder.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'ein-log)
(require 'ein-latex)
(require 'ein-nbview-edit)

(declare-function url-retrieve "url")
(declare-function ein:nbview-sanitize-svg "ein-nbview-output")

(defcustom ein:nbview-fetch-remote-images nil
  "Whether Markdown previews download images from http(s) URLs.
When nil, a remote image shows as a placeholder linking to its URL."
  :type 'boolean
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-image-max-width 0.9
  "Maximum width of images in previews and outputs.
A float is a fraction of the window width; an integer is pixels."
  :type '(choice (float :tag "Fraction of the window width")
                 (natnum :tag "Pixels"))
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-image-max-height 600
  "Maximum height of images in previews and outputs, in pixels."
  :type 'natnum
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defcustom ein:nbview-remote-image-max-bytes (* 5 1024 1024)
  "Largest remote image a preview downloads, in bytes."
  :type 'natnum
  :group 'ein-nbview
  :package-version '(ein . "0.18"))

(defface ein:nbview-md-h1 '((t :inherit outline-1 :weight bold :height 1.3))
  "Level 1 headings in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))
(defface ein:nbview-md-h2 '((t :inherit outline-2 :weight bold :height 1.2))
  "Level 2 headings in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))
(defface ein:nbview-md-h3 '((t :inherit outline-3 :weight bold :height 1.1))
  "Level 3 headings in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))
(defface ein:nbview-md-h4 '((t :inherit outline-4 :weight bold))
  "Level 4 headings in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))
(defface ein:nbview-md-h5 '((t :inherit outline-5 :weight bold))
  "Level 5 headings in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))
(defface ein:nbview-md-h6 '((t :inherit outline-6 :weight bold))
  "Level 6 headings in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))

(defface ein:nbview-md-code
  '((((class color) (min-colors 88) (background light))
     :inherit fixed-pitch :background "#f0f0f0")
    (((class color) (min-colors 88) (background dark))
     :inherit fixed-pitch :background "#2a2a2a")
    (t :inherit fixed-pitch))
  "Inline code and code blocks in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))

(defface ein:nbview-md-strike '((t :strike-through t))
  "Strikethrough text in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))

(defface ein:nbview-md-link '((t :inherit link))
  "Links in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))

(defface ein:nbview-md-table '((t :inherit default))
  "Tables in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))

(defface ein:nbview-md-markup '((t :inherit shadow))
  "Quote bars, rules, bullets and image placeholders in Markdown previews."
  :group 'ein-nbview :package-version '(ein . "0.18"))

(defface ein:nbview-md-error '((t :inherit warning))
  "Markdown source shown because its preview failed."
  :group 'ein-nbview :package-version '(ein . "0.18"))

;;; Entry point

(defvar ein:nbview-md--context nil
  "The context plist of the rendering in progress.")

(defun ein:nbview-render-markdown (source context)
  "Render the Markdown SOURCE as a propertized string.
CONTEXT is a plist:
  :graphic       non-nil to use images and graphic symbols
  :window-width  window width in pixels, for image scaling
  :notebook-dir  local directory of the notebook, for relative images
  :attachments   the cell's attachments (a plist of name to MIME plist)
  :refresh       function called when an asynchronous part is ready
  :owner         identifies the requester of asynchronous work
SOURCE is not modified.  The result has no trailing newline."
  (let ((ein:nbview-md--context context))
    (mapconcat #'ein:nbview-md--render-block-safely
               (ein:nbview-md--parse
                (split-string (substring-no-properties source) "\n"))
               "\n\n")))

(defun ein:nbview-md--ctx (key)
  "Return KEY's value in the current rendering context."
  (plist-get ein:nbview-md--context key))

;;; Block parser

(defconst ein:nbview-md--fence-re "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\([^`[:space:]]*\\)")
(defconst ein:nbview-md--heading-re "\\` \\{0,3\\}\\(#\\{1,6\\}\\)\\(?:[ \t]+\\(.*?\\)\\)?[ \t]*\\(?:[ \t]#+[ \t]*\\)?\\'")
(defconst ein:nbview-md--hr-re "\\` \\{0,3\\}\\([-*_]\\)\\(?:[ \t]*\\1\\)\\{2,\\}[ \t]*\\'")
(defconst ein:nbview-md--item-re "\\`\\( *\\)\\([-*+]\\|[0-9]\\{1,9\\}[.)]\\)\\(?:[ \t]+\\(.*\\)\\)?\\'")
(defconst ein:nbview-md--quote-re "\\` \\{0,3\\}> ?")
(defconst ein:nbview-md--align-re "\\`[ \t]*|?[ \t]*:?-+:?[ \t]*\\(?:|[ \t]*:?-+:?[ \t]*\\)*|?[ \t]*\\'")
(defconst ein:nbview-md--setext-re "\\` \\{0,3\\}\\(=+\\|-+\\)[ \t]*\\'")

(defun ein:nbview-md--blank-p (line)
  "Return non-nil when LINE is empty or whitespace only."
  (string-match-p "\\`[ \t]*\\'" line))

(defun ein:nbview-md--math-start-p (line)
  "Return non-nil when LINE opens a display math block."
  (let ((l (string-trim-left line)))
    (or (string-prefix-p "$$" l) (string-prefix-p "\\[" l))))

(defun ein:nbview-md--table-start-p (line next)
  "Return non-nil when LINE and NEXT start a table.
NEXT must be the delimiter row."
  (and next (string-search "|" line)
       (string-search "-" next)
       (string-match-p ein:nbview-md--align-re next)))

(defun ein:nbview-md--block-start-p (line next)
  "Non-nil when LINE (followed by NEXT) starts a block other than a paragraph."
  (or (string-match-p ein:nbview-md--fence-re line)
      (string-match-p ein:nbview-md--heading-re line)
      (string-match-p ein:nbview-md--hr-re line)
      (string-match-p ein:nbview-md--quote-re line)
      (string-match-p ein:nbview-md--item-re line)
      (ein:nbview-md--math-start-p line)
      (ein:nbview-md--table-start-p line next)))

(defun ein:nbview-md--parse (lines)
  "Parse LINES (a list of strings) into a list of block plists."
  (let ((lines (vconcat lines)) (i 0) blocks)
    (cl-flet ((line (k) (and (< k (length lines)) (aref lines k))))
      (while (< i (length lines))
        (let ((line (aref lines i)) (next (line (1+ i))))
          (cond
           ((ein:nbview-md--blank-p line) (cl-incf i))
           ;; Fenced code; an unclosed fence runs to the end.
           ((string-match ein:nbview-md--fence-re line)
            (let* ((fence (match-string 1 line))
                   (lang (match-string 2 line))
                   (close (format "\\` \\{0,3\\}%s%s*[ \t]*\\'"
                                  (regexp-quote fence) (regexp-quote (substring fence 0 1))))
                   body)
              (cl-incf i)
              (while (and (< i (length lines)) (not (string-match-p close (aref lines i))))
                (push (aref lines i) body)
                (cl-incf i))
              (cl-incf i)
              (push (list :type 'code :lang lang
                          :text (string-join (nreverse body) "\n"))
                    blocks)))
           ;; Display math.
           ((ein:nbview-md--math-start-p line)
            (let* ((l (string-trim line))
                   (dollar (string-prefix-p "$$" l))
                   (open (if dollar "$$" "\\["))
                   (close (if dollar "$$" "\\]"))
                   (rest (substring l 2))
                   (end (string-search close rest))
                   body)
              (cond
               (end
                (push (list :type 'math :text (substring rest 0 end)) blocks)
                (cl-incf i))
               (t
                (push rest body)
                (cl-incf i)
                (while (and (< i (length lines)) (not (string-search close (aref lines i))))
                  (push (aref lines i) body)
                  (cl-incf i))
                (when (< i (length lines))
                  (push (substring (aref lines i) 0 (string-search close (aref lines i))) body)
                  (cl-incf i))
                (push (list :type 'math :text (string-join (nreverse body) "\n")) blocks)))
              (ignore open)))
           ;; ATX heading.
           ((string-match ein:nbview-md--heading-re line)
            (push (list :type 'heading :level (length (match-string 1 line))
                        :text (or (match-string 2 line) ""))
                  blocks)
            (cl-incf i))
           ;; Rule (before lists: "* * *").
           ((string-match-p ein:nbview-md--hr-re line)
            (push (list :type 'hr) blocks)
            (cl-incf i))
           ;; Table.
           ((ein:nbview-md--table-start-p line next)
            (let ((rows (list line)) (align next))
              (cl-incf i 2)
              (while (and (< i (length lines))
                          (not (ein:nbview-md--blank-p (aref lines i)))
                          (string-search "|" (aref lines i)))
                (push (aref lines i) rows)
                (cl-incf i))
              (push (list :type 'table :rows (nreverse rows) :align align) blocks)))
           ;; Block quote.
           ((string-match-p ein:nbview-md--quote-re line)
            (let (body)
              (while (and (< i (length lines))
                          (string-match ein:nbview-md--quote-re (aref lines i)))
                (push (substring (aref lines i) (match-end 0)) body)
                (cl-incf i))
              (push (list :type 'quote :blocks (ein:nbview-md--parse (nreverse body)))
                    blocks)))
           ;; List.
           ((string-match-p ein:nbview-md--item-re line)
            (let (items)
              (while (and (< i (length lines))
                          (string-match ein:nbview-md--item-re (aref lines i)))
                (let* ((cur (aref lines i))
                       (indent (length (match-string 1 cur)))
                       (marker (match-string 2 cur))
                       (text (or (match-string 3 cur) ""))
                       (check (and (string-match "\\`\\[\\([ xX]\\)\\][ \t]+" text)
                                   (prog1 (if (equal " " (match-string 1 text)) 'open 'done)
                                     (setq text (substring text (match-end 0)))))))
                  (cl-incf i)
                  ;; Continuation lines.
                  (while (and (< i (length lines))
                              (not (ein:nbview-md--blank-p (aref lines i)))
                              (not (string-match-p ein:nbview-md--item-re (aref lines i)))
                              (not (ein:nbview-md--block-start-p (aref lines i) (line (1+ i)))))
                    (setq text (concat text " " (string-trim (aref lines i))))
                    (cl-incf i))
                  (push (list :indent indent :marker marker :check check :text text) items))
                ;; A blank line between items keeps the list going.
                (when (and (< i (length lines)) (ein:nbview-md--blank-p (aref lines i))
                           (line (1+ i)) (string-match-p ein:nbview-md--item-re (line (1+ i))))
                  (cl-incf i)))
              (push (list :type 'list :items (nreverse items)) blocks)))
           ;; Paragraph, or setext heading.
           (t
            (let ((body (list line)) level)
              (cl-incf i)
              (while (and (< i (length lines))
                          (not level)
                          (not (ein:nbview-md--blank-p (aref lines i))))
                (let ((cur (aref lines i)))
                  (cond
                   ((string-match ein:nbview-md--setext-re cur)
                    (setq level (if (eq ?= (aref (match-string 1 cur) 0)) 1 2))
                    (cl-incf i))
                   ((ein:nbview-md--block-start-p cur (line (1+ i)))
                    (setq level 'stop))
                   (t (push cur body) (cl-incf i)))))
              (setq body (nreverse body))
              (push (if (numberp level)
                        (list :type 'heading :level level
                              :text (string-join (mapcar #'string-trim body) " "))
                      (list :type 'para :lines body))
                    blocks)))))))
    (nreverse blocks)))

;;; Blocks

(defun ein:nbview-md--render-block-safely (block)
  "Render BLOCK; on error, its literal source in the error face."
  (condition-case err
      (ein:nbview-md--render-block block)
    (error
     (ein:log 'debug "Markdown block failed to render: %s" (error-message-string err))
     (propertize (format "%S" (or (plist-get block :text) (plist-get block :lines) ""))
                 'face 'ein:nbview-md-error))))

(defun ein:nbview-md--faced (string face)
  "STRING with FACE appended to its faces."
  (add-face-text-property 0 (length string) face t string)
  string)

(defun ein:nbview-md--render-block (block)
  "Return the rendered string of the parsed BLOCK."
  (pcase (plist-get block :type)
    ('heading
     (ein:nbview-md--faced (ein:nbview-md--inline (string-trim (plist-get block :text)))
                           (intern (format "ein:nbview-md-h%d" (plist-get block :level)))))
    ('para
     (let ((lines (plist-get block :lines)) parts)
       (while lines
         (let ((l (car lines)))
           (push (string-trim-left l) parts)
           (when (cdr lines)
             (push (if (string-match-p "\\(?:  \\|\\\\\\)\\'" l) "\n" " ") parts))
           (setq lines (cdr lines))))
       (ein:nbview-md--inline
        (replace-regexp-in-string
         "\\(?:  +\\|\\\\\\)\n" "\n"
         (string-trim-right (apply #'concat (nreverse parts)))))))
    ('code (ein:nbview-md--code (plist-get block :text) (plist-get block :lang)))
    ('math (ein:nbview-md--math (plist-get block :text) t))
    ('hr (propertize (make-string 40 ?─) 'face 'ein:nbview-md-markup))
    ('quote
     (let ((inner (mapconcat #'ein:nbview-md--render-block-safely
                             (plist-get block :blocks) "\n\n"))
           (bar (propertize "│ " 'face 'ein:nbview-md-markup)))
       (mapconcat (lambda (l) (concat bar l)) (split-string inner "\n") "\n")))
    ('list (mapconcat #'ein:nbview-md--item (plist-get block :items) "\n"))
    ('table (ein:nbview-md--table (plist-get block :rows) (plist-get block :align)))
    (_ "")))

(defun ein:nbview-md--item (item)
  "Return the rendered string of the list ITEM."
  (let* ((graphic (ein:nbview-md--ctx :graphic))
         (marker (plist-get item :marker))
         (prefix (pcase (plist-get item :check)
                   ('done (if graphic "☑" "[x]"))
                   ('open (if graphic "☐" "[ ]"))
                   (_ (if (string-match-p "\\`[0-9]" marker) marker "•")))))
    (concat (make-string (plist-get item :indent) ?\s)
            (propertize prefix 'face 'ein:nbview-md-markup)
            " "
            (ein:nbview-md--inline (plist-get item :text)))))

(defun ein:nbview-md--code (text lang)
  "TEXT of a fenced block in language LANG, fontified."
  (let ((s (copy-sequence text))
        (mode (and (not (string-empty-p lang))
                   (<= (length text) ein:nbview-native-fontify-max-chars)
                   (ein:nbview--language-mode lang))))
    (when (and mode (not (eq mode 'prog-mode)) (fboundp mode) (not (string-empty-p s)))
      (let (props)
        (ein:nbview--in-shadow mode text
          (let ((font-lock-fontified nil))
            (ignore-errors (font-lock-ensure)))
          (setq props (nconc (ein:nbview--shadow-props 'face)
                             (ein:nbview--shadow-props 'font-lock-face))))
        (pcase-dolist (`(,from ,to ,value) props)
          (add-face-text-property from to value t s))))
    (ein:nbview-md--faced s 'ein:nbview-md-code)))

(defun ein:nbview-md--math (formula display)
  "Return FORMULA as an image when possible, else as text.
DISPLAY non-nil renders display math rather than inline math."
  (if (and (ein:nbview-md--ctx :graphic) (ein:latex-available-p))
      (let ((refresh (ein:nbview-md--ctx :refresh)))
        (ein:latex-render formula display
                          (lambda (_) (when refresh (funcall refresh)))
                          (ein:nbview-md--ctx :owner)))
    (propertize (ein:latex-to-text (string-trim formula)) 'face 'ein:latex-face)))

;;; Tables

(defun ein:nbview-md--split-row (row)
  "Cells of the table ROW, unescaping \\|."
  (let* ((r (string-trim row))
         (r (if (string-prefix-p "|" r) (substring r 1) r))
         (r (if (and (string-suffix-p "|" r) (not (string-suffix-p "\\|" r)))
                (substring r 0 -1)
              r))
         (cells nil) (start 0) (i 0))
    (while (< i (length r))
      (pcase (aref r i)
        (?\\ (cl-incf i))
        (?| (push (substring r start i) cells) (setq start (1+ i))))
      (cl-incf i))
    (push (substring r start) cells)
    (mapcar (lambda (c) (string-trim (string-replace "\\|" "|" c))) (nreverse cells))))

(defun ein:nbview-md--pad (string width align)
  "Pad STRING to WIDTH columns, aligned per ALIGN.
ALIGN is `left', `right' or `center'."
  (let* ((gap (max 0 (- width (string-width string))))
         (left (pcase align ('right gap) ('center (/ gap 2)) (_ 0))))
    (concat (make-string left ?\s) string (make-string (- gap left) ?\s))))

(defun ein:nbview-md--table (rows align)
  "Return the table ROWS rendered with column alignments from ALIGN."
  (let* ((aligns (mapcar (lambda (c)
                           (cond ((and (string-prefix-p ":" c) (string-suffix-p ":" c)) 'center)
                                 ((string-suffix-p ":" c) 'right)
                                 (t 'left)))
                         (ein:nbview-md--split-row align)))
         (ncols (length aligns))
         (cells (mapcar (lambda (row)
                          (let ((cs (mapcar #'ein:nbview-md--inline
                                            (ein:nbview-md--split-row row))))
                            (append (seq-take cs ncols)
                                    (make-list (max 0 (- ncols (length cs))) ""))))
                        rows))
         (widths (cl-loop for k below ncols
                          collect (max 1 (apply #'max (mapcar (lambda (r) (string-width (nth k r)))
                                                              cells)))))
         (sep (propertize " │ " 'face 'ein:nbview-md-markup))
         (render (lambda (row)
                   (ein:nbview-md--faced
                    (mapconcat #'identity
                               (cl-mapcar #'ein:nbview-md--pad row widths aligns)
                               sep)
                    'ein:nbview-md-table)))
         (rule (propertize (mapconcat (lambda (w) (make-string w ?─)) widths "─┼─")
                           'face 'ein:nbview-md-markup)))
    (string-join (append (list (funcall render (car cells)) rule)
                         (mapcar render (cdr cells)))
                 "\n")))

;;; Inline

(defconst ein:nbview-md--punct "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

(defun ein:nbview-md--find-closer (text start delim min max)
  "Position of a closing DELIM run in TEXT after START, or nil.
The run, of length between MIN and MAX (or longer, taking its last
MIN characters), must follow a non-space character."
  (let ((i start) (n (length text)) (c (aref delim 0)) found)
    (while (and (< i n) (not found))
      (cond
       ((eq (aref text i) ?\\) (cl-incf i 2))
       ((eq (aref text i) ?`)
        ;; Skip code spans.
        (let ((end (ein:nbview-md--code-span-end text i)))
          (setq i (if end (car end) (1+ i)))))
       ((eq (aref text i) c)
        (let ((j i))
          (while (and (< j n) (eq (aref text j) c)) (cl-incf j))
          (let ((len (- j i)))
            (if (and (> i start)
                     (not (memq (aref text (1- i)) '(?\s ?\t ?\n)))
                     (or (and (>= len min) (<= len max)) (>= len 3))
                     (not (and (eq c ?_) (< j n)
                               (string-match-p "[[:alnum:]]" (string (aref text j))))))
                (setq found (- j min))
              (setq i j)))))
       (t (cl-incf i))))
    found))

(defun ein:nbview-md--code-span-end (text i)
  "For a backtick run at I in TEXT, (END . CONTENT) of its code span, or nil."
  (let ((j i) (n (length text)))
    (while (and (< j n) (eq (aref text j) ?`)) (cl-incf j))
    (let* ((run (substring text i j))
           (re (concat "\\(?:\\`\\|[^`]\\)\\(" (regexp-quote run) "\\)\\(?:[^`]\\|\\'\\)"))
           (pos (and (string-match re text (1- j)) (match-beginning 1))))
      (when (and pos (>= pos j))
        (let ((content (substring text j pos)))
          (when (and (string-prefix-p " " content) (string-suffix-p " " content)
                     (> (length content) 1))
            (setq content (substring content 1 -1)))
          (cons (+ pos (length run)) content))))))

(defun ein:nbview-md--bracket-end (text i)
  "For a `[' at I in TEXT, the position of its matching `]', or nil."
  (let ((depth 0) (j i) (n (length text)) end)
    (while (and (< j n) (not end))
      (pcase (aref text j)
        (?\\ (cl-incf j))
        (?\[ (cl-incf depth))
        (?\] (when (= 0 (cl-decf depth)) (setq end j))))
      (cl-incf j))
    end))

(defun ein:nbview-md--destination (text i)
  "For a `(' at I in TEXT, (END URL) of a link destination, or nil."
  (when (and (< i (length text)) (eq (aref text i) ?\())
    (let ((depth 0) (j i) (n (length text)) end)
      (while (and (< j n) (not end))
        (pcase (aref text j)
          (?\\ (cl-incf j))
          (?\( (cl-incf depth))
          (?\) (when (= 0 (cl-decf depth)) (setq end j))))
        (cl-incf j))
      (when end
        (let* ((inner (string-trim (substring text (1+ i) end)))
               (url (if (string-match "\\`<\\([^>]*\\)>" inner)
                        (match-string 1 inner)
                      (car (split-string inner "[ \t]+" t)))))
          (list (1+ end) (or url "")))))))

(defun ein:nbview-md--link (label url)
  "LABEL as a button opening URL when clicked."
  (let ((s (if (string-empty-p label) (copy-sequence url) label)))
    (ein:nbview-md--faced
     (make-text-button s nil 'ein-url url 'help-echo url 'mouse-face 'highlight
                       'follow-link t)
     'ein:nbview-md-link)))

(defun ein:nbview-md--emphasis (text i delim face)
  "Emphasis of TEXT opening with DELIM at I: (END . STRING), or nil."
  (let* ((len (length delim))
         (start (+ i len)))
    (when (and (< start (length text))
               (not (memq (aref text start) '(?\s ?\t ?\n)))
               (not (and (eq (aref delim 0) ?_) (> i 0)
                         (string-match-p "[[:alnum:]]" (string (aref text (1- i)))))))
      (when-let* ((close (ein:nbview-md--find-closer text start delim len len)))
        (when (> close start)
          (cons (+ close len)
                (ein:nbview-md--faced (ein:nbview-md--inline (substring text start close))
                                      face)))))))

(defun ein:nbview-md--math-inline (text i)
  "Inline math of TEXT at I: (END . STRING), or nil."
  (cond
   ((string-prefix-p "$$" (substring text i (min (length text) (+ i 2))))
    (when-let* ((end (string-search "$$" text (+ i 2))))
      (when (> end (+ i 2))
        (cons (+ end 2) (ein:nbview-md--math (substring text (+ i 2) end) t)))))
   ((eq (aref text i) ?$)
    (when (and (< (1+ i) (length text))
               (not (memq (aref text (1+ i)) '(?\s ?\t ?$))))
      (let ((j (1+ i)) end)
        (while (and (not end) (setq j (string-search "$" text j)))
          (if (and (not (eq (aref text (1- j)) ?\\))
                   (not (memq (aref text (1- j)) '(?\s ?\t)))
                   (not (and (< (1+ j) (length text))
                             (string-match-p "[0-9]" (string (aref text (1+ j)))))))
              (setq end j)
            (cl-incf j)))
        (when end
          (cons (1+ end) (ein:nbview-md--math (substring text (1+ i) end) nil))))))
   ((string-prefix-p "\\(" (substring text i (min (length text) (+ i 2))))
    (when-let* ((end (string-search "\\)" text (+ i 2))))
      (cons (+ end 2) (ein:nbview-md--math (substring text (+ i 2) end) nil))))
   ((string-prefix-p "\\[" (substring text i (min (length text) (+ i 2))))
    (when-let* ((end (string-search "\\]" text (+ i 2))))
      (cons (+ end 2) (ein:nbview-md--math (substring text (+ i 2) end) t))))))

(defun ein:nbview-md--inline (text)
  "Render the inline Markdown TEXT."
  (let ((i 0) (n (length text)) (out nil) (plain-start 0))
    (cl-flet ((flush () (when (< plain-start i)
                          (push (substring text plain-start i) out)))
              (emit (res) (push (cdr res) out) (setq i (car res) plain-start i)))
      (while (< i n)
        (let* ((c (aref text i))
               (res
                (pcase c
                  (?\\ (or (ein:nbview-md--math-inline text i)
                           (and (< (1+ i) n)
                                (string-search (string (aref text (1+ i)))
                                               ein:nbview-md--punct)
                                (cons (+ i 2) (string (aref text (1+ i)))))))
                  (?` (when-let* ((r (ein:nbview-md--code-span-end text i)))
                        (cons (car r) (ein:nbview-md--faced (copy-sequence (cdr r))
                                                            'ein:nbview-md-code))))
                  (?$ (ein:nbview-md--math-inline text i))
                  (?! (when (and (< (1+ i) n) (eq (aref text (1+ i)) ?\[))
                        (when-let* ((close (ein:nbview-md--bracket-end text (1+ i)))
                                    (dest (ein:nbview-md--destination text (1+ close))))
                          (cons (car dest)
                                (ein:nbview-md--image (substring text (+ i 2) close)
                                                      (cadr dest))))))
                  (?\[ (when-let* ((close (ein:nbview-md--bracket-end text i))
                                   (dest (ein:nbview-md--destination text (1+ close))))
                         (cons (car dest)
                               (ein:nbview-md--link
                                (ein:nbview-md--inline (substring text (1+ i) close))
                                (cadr dest)))))
                  (?< (when (eq i (string-match "<\\([a-zA-Z][a-zA-Z0-9+.-]*:[^ <>]+\\)>" text i))
                        (cons (match-end 0)
                              (ein:nbview-md--link "" (match-string 1 text)))))
                  (?h (when (and (or (= i 0)
                                     (not (string-match-p "[[:alnum:]]" (string (aref text (1- i))))))
                                 (eq i (string-match "https?://[^][ \t\n<>()\"]+" text i)))
                        (let ((end (match-end 0)))
                          (while (memq (aref text (1- end)) '(?. ?, ?\; ?: ?! ??))
                            (cl-decf end))
                          (cons end (ein:nbview-md--link "" (substring text i end))))))
                  ((or ?* ?_)
                   (let ((strong (string (if (eq c ?*) ?* ?_) (if (eq c ?*) ?* ?_))))
                     (or (and (string-prefix-p strong (substring text i (min n (+ i 2))))
                              (ein:nbview-md--emphasis text i strong 'bold))
                         (ein:nbview-md--emphasis text i (string c) 'italic))))
                  (?~ (and (string-prefix-p "~~" (substring text i (min n (+ i 2))))
                           (ein:nbview-md--emphasis text i "~~" 'ein:nbview-md-strike))))))
          (if res
              (progn (flush) (emit res))
            (cl-incf i))))
      (setq i n)
      (flush))
    (apply #'concat (nreverse out))))

;;; Images

(defconst ein:nbview-md--image-types
  '((:image/png . png) (:image/jpeg . jpeg) (:image/gif . gif) (:image/webp . webp)
    (:image/svg+xml . svg))
  "Attachment MIME types shown as images, by preference.")

(defvar ein:nbview-md--remote-cache (make-hash-table :test #'equal)
  "URL to (TYPE . DATA) of downloaded images, or `pending' or `failed'.")

(defun ein:nbview-md--placeholder (alt &optional url)
  "Return a text placeholder for an image with ALT text.
With URL, the placeholder is a link to it."
  (let ((s (propertize (format "[image%s]" (if (string-empty-p alt) "" (concat " " alt)))
                       'face 'ein:nbview-md-markup)))
    (if url (ein:nbview-md--link s url) s)))

(defun ein:nbview-md--max-size ()
  "Return the image size limit (MAX-WIDTH . MAX-HEIGHT) in pixels."
  (let ((w (or (ein:nbview-md--ctx :window-width) 800)))
    (cons (if (floatp ein:nbview-image-max-width)
              (max 16 (round (* ein:nbview-image-max-width w)))
            ein:nbview-image-max-width)
          ein:nbview-image-max-height)))

(defun ein:nbview-image (data type)
  "An image of DATA (a unibyte string) of TYPE, scaled to the limits.
Return nil when TYPE is not displayable."
  (when (and data (image-type-available-p type))
    (let ((size (ein:nbview-md--max-size)))
      (create-image data type t :max-width (car size) :max-height (cdr size)
                    :ascent 'center))))

(defun ein:nbview-md--file-type (name)
  "Return the image type of the file NAME from its extension, or nil."
  (pcase (downcase (or (file-name-extension name) ""))
    ("png" 'png) ((or "jpg" "jpeg") 'jpeg) ("gif" 'gif) ("webp" 'webp) ("svg" 'svg)))

(defun ein:nbview-md--image-source (src)
  "(TYPE . DATA) of the image at SRC, `remote', or nil."
  (cond
   ((string-prefix-p "attachment:" src)
    (let ((bundle (plist-get (ein:nbview-md--ctx :attachments)
                             (intern (concat ":" (substring src (length "attachment:")))))))
      (cl-loop for (mime . type) in ein:nbview-md--image-types
               for data = (plist-get bundle mime)
               when (stringp data)
               return (cons type (if (eq type 'svg)
                                     (encode-coding-string data 'utf-8)
                                   (ignore-errors
                                     (base64-decode-string
                                      (replace-regexp-in-string "[ \t\n\r]" "" data))))))))
   ((string-match "\\`data:image/\\([a-z+]+\\);base64,\\(.*\\)\\'" src)
    (let ((type (pcase (match-string 1 src)
                  ("png" 'png) ((or "jpeg" "jpg") 'jpeg) ("gif" 'gif) ("webp" 'webp)
                  ("svg+xml" 'svg))))
      (when type
        (cons type (ignore-errors (base64-decode-string (match-string 2 src)))))))
   ((string-match-p "\\`https?://" src) 'remote)
   ((string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" src) nil)
   (t
    (let ((dir (ein:nbview-md--ctx :notebook-dir)))
      (when (and dir (file-directory-p dir))
        (let ((file (expand-file-name (url-unhex-string src) dir))
              (type (ein:nbview-md--file-type src)))
          (when (and type (file-in-directory-p file dir) (file-readable-p file)
                     (file-regular-p file))
            (cons type (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally file)
                         (buffer-string))))))))))

(declare-function url-unhex-string "url-util")
(autoload 'url-unhex-string "url-util")

(defun ein:nbview-md--display-image (alt type data)
  "ALT shown as the image DATA of TYPE, or a placeholder."
  (let* ((data (if (eq type 'svg)
                   (and (fboundp 'ein:nbview-sanitize-svg) (ein:nbview-sanitize-svg data))
                 data))
         (image (and data (ein:nbview-image data type))))
    (if image
        (propertize (format "[image%s]" (if (string-empty-p alt) "" (concat " " alt)))
                    'display image)
      (ein:nbview-md--placeholder alt))))

(defun ein:nbview-md--image (alt src)
  "The image ALT at SRC, as an image in graphic frames, else a placeholder."
  (let ((alt (substring-no-properties (ein:nbview-md--inline alt)))
        (source (ignore-errors (ein:nbview-md--image-source src))))
    (cond
     ((eq source 'remote)
      (let ((cached (gethash src ein:nbview-md--remote-cache)))
        (cond
         ((and (consp cached) (ein:nbview-md--ctx :graphic))
          (ein:nbview-md--display-image alt (car cached) (cdr cached)))
         (t
          (when (and ein:nbview-fetch-remote-images (ein:nbview-md--ctx :graphic)
                     (null cached))
            (ein:nbview-md--fetch src (ein:nbview-md--ctx :refresh)))
          (ein:nbview-md--placeholder alt src)))))
     ((and source (cdr source) (ein:nbview-md--ctx :graphic))
      (ein:nbview-md--display-image alt (car source) (cdr source)))
     (t (ein:nbview-md--placeholder alt)))))

(defun ein:nbview-md--fetch (url refresh)
  "Download the image at URL, then call REFRESH."
  (require 'url)
  (puthash url 'pending ein:nbview-md--remote-cache)
  (condition-case err
      (url-retrieve
       url
       (lambda (status)
         (let ((result 'failed))
           (unwind-protect
               (unless (plist-get status :error)
                 (goto-char (point-min))
                 (when (re-search-forward "\r?\n\r?\n" nil t)
                   (let ((data (buffer-substring-no-properties (point) (point-max)))
                         (type (ein:nbview-md--file-type (car (split-string url "[?#]")))))
                     (when (<= (length data) ein:nbview-remote-image-max-bytes)
                       (setq type (or type (image-type-from-data data)))
                       (when type (setq result (cons type data)))))))
             (puthash url result ein:nbview-md--remote-cache)
             (kill-buffer (current-buffer))
             (when (and refresh (consp result)) (funcall refresh)))))
       nil t t)
    (error
     (puthash url 'failed ein:nbview-md--remote-cache)
     (ein:log 'info "Image download failed: %s" (error-message-string err)))))

(provide 'ein-nbview-markdown)

;;; ein-nbview-markdown.el ends here
