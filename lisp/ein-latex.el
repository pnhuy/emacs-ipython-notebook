;;; ein-latex.el --- LaTeX formulas as images or Unicode text -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-latex.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; ein-latex.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-latex.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Rendering of LaTeX formulas for Markdown previews and outputs.
;;
;; `ein:latex-render' returns at once a text rendering of a formula
;; (Unicode symbols, sub- and superscripts).  When `latex' and either
;; `dvisvgm' or `dvipng' are installed, and the method allows it, it
;; also renders an image asynchronously and hands it to a callback.
;;
;; Safety: latex runs with `-no-shell-escape' and `nonstopmode' in a
;; private (mode 700) temporary directory, deleted after every job.
;; At most `ein:latex-max-processes' jobs run at once, and a job is
;; killed after `ein:latex-timeout' seconds.  Images are cached under
;; `ein:latex-cache-directory', keyed by formula, colour and scale.
;; A formula that fails once keeps its text rendering for the session.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'color)
(require 'ein-log)

(defgroup ein-latex nil
  "LaTeX rendering in EIN previews and outputs."
  :group 'ein
  :package-version '(ein . "0.18"))

(defcustom ein:latex-render-method 'auto
  "How LaTeX formulas are shown.
`auto': as images when latex and dvisvgm or dvipng are installed and
the frame shows images, else as Unicode text.
`image': like `auto'; text is used only when the tools are missing.
`text': always as Unicode text; no process is started."
  :type '(choice (const :tag "Images when possible" auto)
                 (const :tag "Images" image)
                 (const :tag "Unicode text" text))
  :package-version '(ein . "0.18"))

(defcustom ein:latex-scale 1.0
  "Scale of LaTeX images relative to the default font.
At 1.0 a formula's em is as large as the default font's."
  :type 'number
  :package-version '(ein . "0.18"))

(defcustom ein:latex-max-processes 2
  "Maximum number of LaTeX jobs running at the same time."
  :type 'natnum
  :package-version '(ein . "0.18"))

(defcustom ein:latex-timeout 20
  "Seconds after which a LaTeX job is killed and counted as failed."
  :type 'number
  :package-version '(ein . "0.18"))

(defcustom ein:latex-cache-directory (locate-user-emacs-file "ein/latex-cache/")
  "Directory caching rendered LaTeX images."
  :type 'directory
  :package-version '(ein . "0.18"))

(defface ein:latex-face '((t :inherit font-lock-constant-face))
  "Face of LaTeX formulas shown as text."
  :package-version '(ein . "0.18"))

;;; Unicode text

(defconst ein:latex--symbols
  (let ((h (make-hash-table :test #'equal)))
    (cl-loop for (k v) on
             '("alpha" "α" "beta" "β" "gamma" "γ" "delta" "δ" "epsilon" "ϵ"
               "varepsilon" "ε" "zeta" "ζ" "eta" "η" "theta" "θ" "vartheta" "ϑ"
               "iota" "ι" "kappa" "κ" "lambda" "λ" "mu" "μ" "nu" "ν" "xi" "ξ"
               "pi" "π" "varpi" "ϖ" "rho" "ρ" "varrho" "ϱ" "sigma" "σ"
               "varsigma" "ς" "tau" "τ" "upsilon" "υ" "phi" "ϕ" "varphi" "φ"
               "chi" "χ" "psi" "ψ" "omega" "ω"
               "Gamma" "Γ" "Delta" "Δ" "Theta" "Θ" "Lambda" "Λ" "Xi" "Ξ"
               "Pi" "Π" "Sigma" "Σ" "Upsilon" "Υ" "Phi" "Φ" "Psi" "Ψ" "Omega" "Ω"
               "le" "≤" "leq" "≤" "ge" "≥" "geq" "≥" "ne" "≠" "neq" "≠"
               "ll" "≪" "gg" "≫" "approx" "≈" "sim" "∼" "simeq" "≃" "cong" "≅"
               "equiv" "≡" "propto" "∝" "infty" "∞" "sum" "∑" "prod" "∏"
               "int" "∫" "iint" "∬" "oint" "∮" "partial" "∂" "nabla" "∇"
               "pm" "±" "mp" "∓" "times" "×" "cdot" "·" "div" "÷" "ast" "∗"
               "star" "⋆" "circ" "∘" "bullet" "•" "oplus" "⊕" "otimes" "⊗"
               "to" "→" "rightarrow" "→" "leftarrow" "←" "gets" "←"
               "leftrightarrow" "↔" "Rightarrow" "⇒" "Leftarrow" "⇐"
               "Leftrightarrow" "⇔" "implies" "⇒" "iff" "⇔" "mapsto" "↦"
               "uparrow" "↑" "downarrow" "↓" "in" "∈" "notin" "∉" "ni" "∋"
               "subset" "⊂" "subseteq" "⊆" "supset" "⊃" "supseteq" "⊇"
               "cup" "∪" "cap" "∩" "setminus" "∖" "emptyset" "∅" "varnothing" "∅"
               "forall" "∀" "exists" "∃" "neg" "¬" "lnot" "¬" "land" "∧"
               "wedge" "∧" "lor" "∨" "vee" "∨" "perp" "⊥" "parallel" "∥"
               "angle" "∠" "degree" "°" "prime" "′" "hbar" "ℏ" "ell" "ℓ"
               "Re" "ℜ" "Im" "ℑ" "aleph" "ℵ" "cdots" "⋯" "ldots" "…" "dots" "…"
               "vdots" "⋮" "ddots" "⋱" "langle" "⟨" "rangle" "⟩"
               "lfloor" "⌊" "rfloor" "⌋" "lceil" "⌈" "rceil" "⌉"
               "mid" "∣" "vert" "|" "Vert" "‖" "quad" "  " "qquad" "    "
               "log" "log" "ln" "ln" "exp" "exp" "sin" "sin" "cos" "cos"
               "tan" "tan" "max" "max" "min" "min" "lim" "lim" "det" "det"
               "sup" "sup" "inf" "inf" "arg" "arg")
             by #'cddr do (puthash k v h))
    h)
  "LaTeX command names and their Unicode text.")

(defconst ein:latex--blackboard
  '((?R . "ℝ") (?N . "ℕ") (?Z . "ℤ") (?Q . "ℚ") (?C . "ℂ") (?P . "ℙ") (?H . "ℍ"))
  "Blackboard bold letters.")

(defconst ein:latex--superscripts
  (cl-pairlis
   (string-to-list "0123456789+-=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVW")
   (string-to-list "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ"))
  "Characters with a Unicode superscript form.")

(defconst ein:latex--subscripts
  (cl-pairlis
   (string-to-list "0123456789+-=()aehijklmnoprstuvx")
   (string-to-list "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"))
  "Characters with a Unicode subscript form.")

(defun ein:latex--group (s i)
  "Read the brace group of S opening at I.
Return (CONTENT . END) where END follows the closing brace; an
unclosed group runs to the end of S."
  (let ((depth 0) (j i) (n (length s)) end)
    (while (and (< j n) (not end))
      (pcase (aref s j)
        (?\\ (cl-incf j))
        (?{ (cl-incf depth))
        (?} (when (= 0 (cl-decf depth)) (setq end j))))
      (cl-incf j))
    (cons (substring s (1+ i) (or end n)) (if end (1+ end) n))))

(defun ein:latex--argument (s i)
  "Read the argument of a command or script in S at I, skipping spaces.
Return (RAW CONTENT END BRACED) or nil at the end of S."
  (let ((n (length s)))
    (while (and (< i n) (eq (aref s i) ?\s)) (cl-incf i))
    (cond
     ((>= i n) nil)
     ((eq (aref s i) ?{)
      (pcase-let ((`(,content . ,end) (ein:latex--group s i)))
        (list (substring s i end) content end t)))
     ((and (eq (aref s i) ?\\) (< (1+ i) n))
      (let ((end (if (string-match "\\\\[A-Za-z]+" s i)
                     (if (= (match-beginning 0) i) (match-end 0) (+ i 2))
                   (+ i 2))))
        (list (substring s i end) (substring s i end) end nil)))
     (t (list (substring s i (1+ i)) (substring s i (1+ i)) (1+ i) nil)))))

(defun ein:latex--script (text table)
  "The single character TEXT mapped by TABLE, or nil.
Longer scripts stay as written: a run of small letters reads badly."
  (when-let* (((= 1 (length text)))
              (c (alist-get (aref text 0) table)))
    (string c)))

(defun ein:latex-to-text (formula)
  "Render the LaTeX FORMULA as Unicode text.
Known commands become symbols, single-character scripts become
Unicode sub- and superscripts; anything else is kept as written."
  (let ((i 0) (n (length formula)) (out nil))
    (while (< i n)
      (let ((c (aref formula i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) n)
               (string-match "\\\\\\([A-Za-z]+\\)" formula i)
               (= (match-beginning 0) i))
          (let ((name (match-string 1 formula)))
            (setq i (match-end 0))
            (pcase name
              ("frac"
               (let* ((a (ein:latex--argument formula i))
                      (b (and a (ein:latex--argument formula (nth 2 a)))))
                 (if (not b)
                     (push "\\frac" out)
                   (push (format "(%s)/(%s)" (ein:latex-to-text (nth 1 a))
                                 (ein:latex-to-text (nth 1 b)))
                         out)
                   (setq i (nth 2 b)))))
              ("sqrt"
               (let ((a (ein:latex--argument formula i)))
                 (if (not a)
                     (push "√" out)
                   (push (format "√(%s)" (ein:latex-to-text (nth 1 a))) out)
                   (setq i (nth 2 a)))))
              ((or "mathbb" "mathbf" "mathrm" "mathit" "mathsf" "mathtt"
                   "mathcal" "text" "textrm" "textbf" "textit" "operatorname"
                   "boldsymbol")
               (let ((a (ein:latex--argument formula i)))
                 (when a
                   (setq i (nth 2 a))
                   (push (if (equal name "mathbb")
                             (mapconcat (lambda (ch)
                                          (or (alist-get ch ein:latex--blackboard)
                                              (string ch)))
                                        (nth 1 a) "")
                           (ein:latex-to-text (nth 1 a)))
                         out))))
              ((or "left" "right" "big" "Big" "bigg" "Bigg" "displaystyle"
                   "textstyle" "limits" "nolimits")
               (when (and (member name '("left" "right")) (< i n)
                          (eq (aref formula i) ?.))
                 (cl-incf i)))
              (_ (push (gethash name ein:latex--symbols (concat "\\" name)) out)))))
         ((and (eq c ?\\) (< (1+ i) n))
          (let ((d (aref formula (1+ i))))
            (push (pcase d
                    ((or ?, ?: ?\; ?\s) " ")
                    (?! "")
                    (?\\ " ")
                    (_ (string d)))
                  out)
            (cl-incf i 2)))
         ((memq c '(?^ ?_))
          (let ((a (ein:latex--argument formula (1+ i))))
            (if (not a)
                (progn (push (string c) out) (cl-incf i))
              (let* ((text (ein:latex-to-text (nth 1 a)))
                     (mapped (ein:latex--script
                              text
                              (if (eq c ?^) ein:latex--superscripts
                                ein:latex--subscripts))))
                ;; Unmapped scripts keep their braces, with the
                ;; commands inside converted: e^{i\pi} -> e^{iπ}.
                (push (or mapped
                          (concat (string c)
                                  (if (= (length text) 1) text (concat "{" text "}"))))
                      out)
                (setq i (nth 2 a))))))
         ((eq c ?{)
          (pcase-let ((`(,content . ,end) (ein:latex--group formula i)))
            (push (ein:latex-to-text content) out)
            (setq i end)))
         (t (push (string c) out) (cl-incf i)))))
    (apply #'concat (nreverse out))))

;;; Tools

(defvar ein:latex--tools 'unknown
  "Plist of the LaTeX tools found, nil when missing, `unknown' before a lookup.
Keys: `:latex', and `:svg' (dvisvgm) or `:png' (dvipng).")

(defun ein:latex--tools ()
  "The LaTeX tools, looked up once."
  (when (eq ein:latex--tools 'unknown)
    (let ((latex (executable-find "latex"))
          (svg (and (image-type-available-p 'svg) (executable-find "dvisvgm")))
          (png (and (image-type-available-p 'png) (executable-find "dvipng"))))
      (setq ein:latex--tools
            (and latex (or svg png)
                 (list :latex latex :svg svg :png (and (not svg) png))))))
  ein:latex--tools)

(defun ein:latex-available-p ()
  "Non-nil when formulas are rendered as images."
  (and (not (eq ein:latex-render-method 'text))
       (ein:latex--tools)
       t))

;;; Jobs

(defvar ein:latex--queue nil "Jobs waiting for a free process slot, oldest first.")
(defvar ein:latex--active nil "Jobs running.")
(defvar ein:latex--running 0 "Number of running jobs.")
(defvar ein:latex--failed (make-hash-table :test #'equal)
  "Cache keys of formulas that failed to render.")

(cl-defstruct (ein:latex--job (:constructor ein:latex--job-create))
  key formula display file type callbacks dir process timer)

(defun ein:latex--foreground ()
  "The default foreground as RRGGBB, black when unknown."
  (let* ((fg (face-attribute 'default :foreground nil t))
         (rgb (and (stringp fg) (not (string-prefix-p "unspecified" fg))
                   (color-name-to-rgb fg))))
    (if rgb
        (apply #'format "%02X%02X%02X" (mapcar (lambda (x) (round (* 255 x))) rgb))
      "000000")))

(defun ein:latex--font-px ()
  "Pixel size of the default font: the size of one em in the buffer."
  (or (ignore-errors
        (let ((font (face-font 'default)))
          (and font (aref (font-info font) 2))))
      (frame-char-height)))

(defun ein:latex--px-per-pt ()
  "Pixels per TeX point that draw a 10pt em as large as the default font."
  (* ein:latex-scale (/ (ein:latex--font-px) 10.0)))

(defun ein:latex--png-dpi ()
  "Resolution at which dvipng renders formulas at the default font size."
  (round (* 72.27 (ein:latex--px-per-pt))))

(defun ein:latex--svg-height-pt (file)
  "The height of the SVG FILE in points, or nil."
  (with-temp-buffer
    (insert-file-contents file nil 0 2048)
    (when (re-search-forward "<svg[^>]*?[ \t\n]height=['\"]\\([0-9.]+\\)pt['\"]" nil t)
      (string-to-number (match-string 1)))))

(defun ein:latex--image (file type)
  "An image descriptor for FILE of TYPE, sized from the default font.
PNGs are rendered at the matching resolution (`ein:latex--png-dpi');
SVGs are scaled from their size in points."
  (let ((pt (and (eq type 'svg) (ein:latex--svg-height-pt file))))
    (apply #'create-image file type nil :ascent 'center :scale 1
           (and pt (list :height (max 1 (round (* pt (ein:latex--px-per-pt)))))))))

(defun ein:latex--with-image (text file type)
  "Return TEXT displayed as the image in FILE of image TYPE."
  (propertize text 'display (ein:latex--image file type)))

(defun ein:latex-render (formula display callback &optional owner)
  "Render the LaTeX FORMULA, in DISPLAY style when DISPLAY is non-nil.
Return a string at once: the image when cached, else the Unicode
text.  When an image is being made, CALLBACK is later called with
the image string, or with the text when rendering failed.  OWNER
identifies the requester for `ein:latex-cancel'."
  (let* ((source (string-trim formula))
         (text (propertize (ein:latex-to-text source) 'face 'ein:latex-face)))
    (if (or (string-empty-p source) (not (ein:latex-available-p)))
        text
      (let* ((tools (ein:latex--tools))
             (type (if (plist-get tools :svg) 'svg 'png))
             ;; SVGs scale when shown; PNGs are rendered at a size.
             (key (sha1 (format "%s\0%s\0%s\0%s" source display
                                (ein:latex--foreground)
                                (if (eq type 'svg) type
                                  (format "%s@%d" type (ein:latex--png-dpi))))))
             (file (expand-file-name (concat key "." (symbol-name type))
                                     ein:latex-cache-directory)))
        (cond
         ((file-exists-p file) (ein:latex--with-image text file type))
         ((gethash key ein:latex--failed) text)
         (t
          (let ((entry (cons owner (lambda (ok)
                                     (funcall callback
                                              (if ok (ein:latex--with-image text file type)
                                                text)))))
                (job (or (cl-find key ein:latex--queue :key #'ein:latex--job-key :test #'equal)
                         (cl-find key ein:latex--active :key #'ein:latex--job-key :test #'equal))))
            (if job
                (push entry (ein:latex--job-callbacks job))
              (setq ein:latex--queue
                    (nconc ein:latex--queue
                           (list (ein:latex--job-create
                                  :key key :formula source :display display
                                  :file file :type type :callbacks (list entry)))))
              (ein:latex--dispatch)))
          text))))))

(defun ein:latex-cancel (owner)
  "Forget the callbacks of OWNER, and drop its jobs still queued."
  (dolist (job (append ein:latex--queue ein:latex--active))
    (setf (ein:latex--job-callbacks job)
          (cl-remove owner (ein:latex--job-callbacks job) :key #'car)))
  (setq ein:latex--queue (cl-remove-if-not #'ein:latex--job-callbacks ein:latex--queue)))

(defun ein:latex--dispatch ()
  "Start queued jobs while process slots are free."
  (while (and ein:latex--queue (< ein:latex--running ein:latex-max-processes))
    (let ((job (pop ein:latex--queue)))
      (cl-incf ein:latex--running)
      (push job ein:latex--active)
      (condition-case err
          (ein:latex--start job)
        (error
         (ein:log 'warn "LaTeX job failed to start: %s" (error-message-string err))
         (ein:latex--finish job nil))))))

(defun ein:latex--document (job)
  "The LaTeX document of JOB."
  (let ((formula (ein:latex--job-formula job)))
    (concat "\\documentclass[preview,border=1pt]{standalone}\n"
            "\\usepackage{amsmath,amssymb}\n\\usepackage{xcolor}\n"
            "\\begin{document}\n"
            (format "\\color[HTML]{%s}\n" (ein:latex--foreground))
            (cond ((string-prefix-p "\\begin{" formula) formula)
                  ((ein:latex--job-display job) (format "$\\displaystyle %s$" formula))
                  (t (format "$%s$" formula)))
            "\n\\end{document}\n")))

(defun ein:latex--start (job)
  "Run latex for JOB in a private temporary directory."
  (let ((dir (make-temp-file "ein-latex-" t)))
    (set-file-modes dir #o700)
    (setf (ein:latex--job-dir job) dir)
    (let ((coding-system-for-write 'utf-8))
      (write-region (ein:latex--document job) nil (expand-file-name "f.tex" dir) nil 'silent))
    (setf (ein:latex--job-timer job)
          (run-at-time ein:latex-timeout nil
                       (lambda ()
                         (let ((p (ein:latex--job-process job)))
                           (when (process-live-p p) (delete-process p)))
                         (ein:latex--finish job nil))))
    (ein:latex--run job (list (plist-get (ein:latex--tools) :latex)
                              "-no-shell-escape" "-interaction=nonstopmode"
                              "-halt-on-error" "f.tex")
                    #'ein:latex--convert)))

(defun ein:latex--run (job command next)
  "Run COMMAND in the directory of JOB, then call NEXT with JOB on success."
  (let ((default-directory (file-name-as-directory (ein:latex--job-dir job))))
    (setf (ein:latex--job-process job)
          (make-process
           :name "ein-latex"
           :command command
           :buffer nil
           :noquery t
           :connection-type 'pipe
           :sentinel (lambda (proc _event)
                       (unless (process-live-p proc)
                         (if (and (eq (process-status proc) 'exit)
                                  (= 0 (process-exit-status proc)))
                             (funcall next job)
                           (ein:latex--finish job nil))))))))

(defun ein:latex--convert (job)
  "Convert the DVI of JOB to an image."
  (if (not (ein:latex--job-dir job))
      (ein:latex--finish job nil)
    (let ((tools (ein:latex--tools)))
      (ein:latex--run
       job
       (if (eq (ein:latex--job-type job) 'svg)
           (list (plist-get tools :svg) "--no-fonts" "--exact-bbox" "-o" "f.svg" "f.dvi")
         (list (plist-get tools :png) "-T" "tight" "-bg" "Transparent"
               "-D" (number-to-string (ein:latex--png-dpi))
               "-o" "f.png" "f.dvi"))
       #'ein:latex--store))))

(defun ein:latex--store (job)
  "Copy the image of JOB to the cache."
  (let ((image (and (ein:latex--job-dir job)
                    (expand-file-name (concat "f." (symbol-name (ein:latex--job-type job)))
                                      (ein:latex--job-dir job)))))
    (if (not (and image (file-exists-p image)))
        (ein:latex--finish job nil)
      (condition-case err
          (progn
            (unless (file-directory-p ein:latex-cache-directory)
              (make-directory ein:latex-cache-directory t)
              (set-file-modes ein:latex-cache-directory #o700))
            (copy-file image (ein:latex--job-file job) t)
            (ein:latex--finish job t))
        (error
         (ein:log 'warn "LaTeX cache write failed: %s" (error-message-string err))
         (ein:latex--finish job nil))))))

(defun ein:latex--finish (job ok)
  "End JOB, successful when OK: clean up, call back, start the next job."
  (when (memq job ein:latex--active)
    (setq ein:latex--active (delq job ein:latex--active))
    (cl-decf ein:latex--running)
    (when (ein:latex--job-timer job) (cancel-timer (ein:latex--job-timer job)))
    (when-let* ((dir (ein:latex--job-dir job)))
      (setf (ein:latex--job-dir job) nil)
      (ignore-errors (delete-directory dir t)))
    (unless ok
      (puthash (ein:latex--job-key job) t ein:latex--failed))
    (dolist (entry (reverse (ein:latex--job-callbacks job)))
      (condition-case err
          (funcall (cdr entry) ok)
        (error (ein:log 'warn "LaTeX callback failed: %s" (error-message-string err)))))
    (ein:latex--dispatch)))

(provide 'ein-latex)

;;; ein-latex.el ends here
