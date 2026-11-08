;;; test-ein-latex.el --- LaTeX rendering for previews and outputs -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-latex.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; test-ein-latex.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-latex.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T130: method selection, the Unicode fallback, and the asynchronous
;; image pipeline (no shell escape, private job directory, cache).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-latex)

(ert-deftest ein:latex-available-p-honours-method ()
  (let ((ein:latex-render-method 'text))
    (should-not (ein:latex-available-p)))
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
    (let ((ein:latex-render-method 'auto)
          (ein:latex--tools 'unknown))
      (should-not (ein:latex-available-p))))
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name &rest _) (concat "/usr/bin/" name)))
            ((symbol-function 'ein:latex--sandbox-works-p) #'always))
    (dolist (method '(auto image))
      (let ((ein:latex-render-method method)
            (ein:latex--tools 'unknown))
        (should (ein:latex-available-p))))))

(ert-deftest ein:latex-needs-a-sandbox ()
  "Without a sandbox, formulas are text unless unsandboxed rendering is allowed.
TeX can read any of your files, and formulas come from notebooks."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name &rest _)
               (unless (equal name "bwrap") (concat "/usr/bin/" name)))))
    (let ((ein:latex-render-method 'image)
          (ein:latex--tools 'unknown))
      (should-not (ein:latex-available-p)))
    (let ((ein:latex-render-method 'image)
          (ein:latex-allow-unsandboxed t)
          (ein:latex--tools 'unknown))
      (should (ein:latex-available-p))
      (should (equal '("latex" "f.tex") (ein:latex--sandbox "/x" '("latex" "f.tex"))))))
  ;; Bubblewrap that cannot make namespaces counts as no sandbox.
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name &rest _) (concat "/usr/bin/" name)))
            ((symbol-function 'ein:latex--sandbox-works-p) #'ignore))
    (let ((ein:latex-render-method 'image)
          (ein:latex--tools 'unknown))
      (should-not (ein:latex-available-p)))))

(ert-deftest ein:latex-text-fallback ()
  (should (equal "α + β ≤ x₁" (ein:latex-to-text "\\alpha + \\beta \\le x_1")))
  (should (equal "α²" (ein:latex-to-text "\\alpha^2")))
  (should (equal "∑ xᵢ ≤ ∞" (ein:latex-to-text "\\sum x_i \\le \\infty")))
  (should (equal "x^{ab}" (ein:latex-to-text "x^{ab}")))
  (should (equal "e^{iπ}" (ein:latex-to-text "e^{i\\pi}")))
  (should (equal "eˣ" (ein:latex-to-text "e^{x}")))
  (should (equal "ℝ → ℕ" (ein:latex-to-text "\\mathbb{R} \\to \\mathbb{N}")))
  (should (equal "(a)/(b)" (ein:latex-to-text "\\frac{a}{b}")))
  (should (equal "√(x)" (ein:latex-to-text "\\sqrt{x}")))
  (should (equal "\\unknown" (ein:latex-to-text "\\unknown")))
  (should (equal "a b" (ein:latex-to-text "a\\,b"))))

(ert-deftest ein:latex-render-text-method ()
  (let ((ein:latex-render-method 'text)
        called)
    (let ((s (ein:latex-render "\\alpha" nil (lambda (&rest _) (setq called t)))))
      (should (equal "α" (substring-no-properties s)))
      (should (memq 'ein:latex-face (ensure-list (get-text-property 0 'face s))))
      (should-not called))))

(ert-deftest ein:latex-image-matches-font-size ()
  "Formula images are sized from the buffer's font, not TeX's 10pt.
Regression: SVGs showed at their natural size in points, far smaller
than a large or HiDPI default font."
  (let ((svg (make-temp-file "ein-latex-size-" nil ".svg"))
        (ein:latex-scale 1.0))
    (unwind-protect
        (progn
          (with-temp-file svg
            (insert "<?xml version='1.0'?>\n<svg version='1.1' "
                    "xmlns='http://www.w3.org/2000/svg' width='40pt' "
                    "height='9pt' viewBox='0 0 40 9'></svg>\n"))
          (cl-letf (((symbol-function 'ein:latex--font-px) (lambda () 20)))
            (let ((image (ein:latex--image svg 'svg)))
              ;; 9pt at a 10pt em, drawn with a 20 pixel em.
              (should (= 18 (image-property image :height)))
              (should (= 1 (image-property image :scale))))
            (let ((ein:latex-scale 1.5))
              (should (= 27 (image-property (ein:latex--image svg 'svg) :height))))
            ;; PNGs are rendered at the resolution that gives that size.
            (should (= 145 (ein:latex--png-dpi)))))
      (delete-file svg))))

(defun ein:testing-latex-tools-p ()
  (and (executable-find "latex")
       (or (executable-find "dvisvgm") (executable-find "dvipng"))))

(ert-deftest ein:latex-render-image ()
  (skip-unless (ein:testing-latex-tools-p))
  (let* ((cache (make-temp-file "ein-latex-cache-" t))
         (ein:latex-cache-directory cache)
         (ein:latex-render-method 'image)
         (ein:latex--tools 'unknown)
         (jobs nil)
         (commands nil)
         (result nil))
    (unwind-protect
        (cl-letf* ((orig-make-temp (symbol-function 'make-temp-file))
                   ((symbol-function 'make-temp-file)
                    (lambda (prefix &rest args)
                      (let ((f (apply orig-make-temp prefix args)))
                        (when (string-prefix-p "ein-latex-" prefix) (push f jobs))
                        f)))
                   (orig-make-process (symbol-function 'make-process))
                   ((symbol-function 'make-process)
                    (lambda (&rest args)
                      (let ((p (apply orig-make-process args)))
                        (push (process-command p) commands)
                        p))))
          (let ((placeholder (ein:latex-render "x^2 + \\alpha" nil
                                               (lambda (s) (setq result s)))))
            (should (equal "x² + α" (substring-no-properties placeholder)))
            (with-timeout (10 (ert-fail "No LaTeX callback within 10 s"))
              (while (not result) (accept-process-output nil 0.05)))
            (should (eq 'image (car-safe (get-text-property 0 'display result))))
            ;; The job directory was private and is gone.
            (should jobs)
            (dolist (j jobs) (should-not (file-exists-p j)))
            (let ((latex (cl-find-if (lambda (c) (member "f.tex" c)) commands)))
              (should (member "-no-shell-escape" latex))
              ;; Run in the sandbox, which hides the home directory.
              (when (plist-get (ein:latex--tools) :bwrap)
                (should (string-suffix-p "bwrap" (car latex)))
                (should (member (expand-file-name "~") latex))))
            ;; Second call: cache hit, image returned directly, no process.
            (setq commands nil)
            (let ((again (ein:latex-render "x^2 + \\alpha" nil
                                           (lambda (&rest _) (ert-fail "Callback on a cache hit")))))
              (should (eq 'image (car-safe (get-text-property 0 'display again))))
              (should-not commands))
            (should (directory-files cache nil "\\`[^.]"))))
      (delete-directory cache t))))

(ert-deftest ein:latex-render-failure ()
  (skip-unless (ein:testing-latex-tools-p))
  (let* ((cache (make-temp-file "ein-latex-cache-" t))
         (ein:latex-cache-directory cache)
         (ein:latex-render-method 'image)
         (ein:latex--tools 'unknown)
         (calls 0) result)
    (unwind-protect
        (progn
          (ein:latex-render "\\badcommand{" nil (lambda (s) (cl-incf calls) (setq result s)))
          (with-timeout (10 (ert-fail "No LaTeX callback within 10 s"))
            (while (not result) (accept-process-output nil 0.05)))
          ;; A failure leaves the text fallback, and is not retried.
          (should-not (get-text-property 0 'display result))
          (ein:latex-render "\\badcommand{" nil (lambda (&rest _) (cl-incf calls)))
          (accept-process-output nil 0.3)
          (should (= 1 calls)))
      (delete-directory cache t))))

(ert-deftest ein:latex-render-cannot-read-files ()
  "A formula cannot \\input a file outside the job directory."
  (skip-unless (ein:testing-latex-tools-p))
  (let* ((cache (make-temp-file "ein-latex-cache-" t))
         (marker (make-temp-file "ein-latex-marker-" nil ".tex" "y"))
         (ein:latex-cache-directory cache)
         (ein:latex-render-method 'image)
         (ein:latex--tools 'unknown)
         result)
    (unwind-protect
        (progn
          (ein:latex-render (format "x\\input{%s}" marker) nil
                            (lambda (s) (setq result s)))
          (with-timeout (10 (ert-fail "No LaTeX callback within 10 s"))
            (while (not result) (accept-process-output nil 0.05)))
          (should-not (get-text-property 0 'display result)))
      (delete-file marker)
      (delete-directory cache t))))

(ert-deftest ein:latex-queue-limit-and-cancel ()
  (let ((ein:latex-render-method 'image)
        (ein:latex--tools '(:latex "latex" :svg "dvisvgm"))
        (ein:latex-max-processes 2)
        (ein:latex--queue nil)
        (ein:latex--running 0)
        (ein:latex-cache-directory (make-temp-file "ein-latex-cache-" t))
        (started 0))
    (unwind-protect
        (cl-letf (((symbol-function 'ein:latex--start) (lambda (_job) (cl-incf started))))
          (dotimes (i 5)
            (ein:latex-render (format "x_%d" i) nil #'ignore 'owner-a))
          (ein:latex-render "y" nil #'ignore 'owner-b)
          (should (= 2 started))
          (should (= 4 (length ein:latex--queue)))
          (ein:latex-cancel 'owner-a)
          (should (= 1 (length ein:latex--queue))))
      (delete-directory ein:latex-cache-directory t))))

(provide 'test-ein-latex)

;;; test-ein-latex.el ends here
