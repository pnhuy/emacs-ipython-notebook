;;; test-ein-ipynb-mode.el --- Visiting ipynb files -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Visiting an ipynb file opens it as a notebook, but only once the
;; buffer is really shown: never from `find-file-noselect', a
;; minibuffer preview, or batch Emacs.

;;; Code:

(require 'ert)
(require 'ein-ipynb-mode)

(defmacro ein:testing-ipynb--visiting (&rest body)
  "Run BODY in an ipynb-mode buffer visiting a temporary file."
  (declare (indent 0))
  `(let* ((file (make-temp-file "ein-ipynb-" nil ".ipynb" "{}"))
          (buffer (let ((ein:ipynb-open-as-notebook nil))
                    (find-file-noselect file))))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (kill-buffer buffer)
       (delete-file file))))

(ert-deftest ein:ipynb-auto-open-only-when-shown ()
  (ein:testing-ipynb--visiting
    (should (derived-mode-p 'ein:ipynb-mode))
    (let ((noninteractive nil)
          (ein:ipynb-open-as-notebook t))
      ;; Not shown in the selected window.
      (should-not (ein:ipynb--auto-open-p buffer))
      (save-window-excursion
        (set-window-buffer (selected-window) buffer)
        (should (ein:ipynb--auto-open-p buffer))
        (let ((ein:ipynb-open-as-notebook nil))
          (should-not (ein:ipynb--auto-open-p buffer)))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () 'mini)))
          (should-not (ein:ipynb--auto-open-p buffer)))
        (set-buffer-modified-p t)
        (should-not (ein:ipynb--auto-open-p buffer))
        (set-buffer-modified-p nil)
        ;; Once only, even after the mode runs again (revert).
        (let (opened)
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_time _repeat fn &rest args) (push (cons fn args) opened))))
            (ein:ipynb--maybe-open (selected-window))
            (ein:ipynb-mode)
            (ein:ipynb--maybe-open (selected-window)))
          (should (= (length opened) 1)))))
    ;; Batch Emacs never opens notebooks by itself.
    (should-not (ein:ipynb--auto-open-p buffer))))

(ert-deftest ein:ipynb-auto-open-failure-keeps-buffer ()
  (ein:testing-ipynb--visiting
    (cl-letf (((symbol-function 'ein:process-open-notebook)
               (lambda (&rest _) (user-error "No jupyter"))))
      (ein:ipynb--open buffer)
      (should (buffer-live-p buffer)))))

(ert-deftest ein:ipynb-visiting-skips-code-modes ()
  "Visiting an ipynb file shows a placeholder, not JSON in a code mode.
So `prog-mode-hook' (eglot, linters) does not run for a buffer that
is about to become a notebook."
  (let (ran)
    (let ((prog-mode-hook (list (lambda () (push 'prog ran))))
          (ein:ipynb-open-as-notebook t))
      (let* ((file (make-temp-file "ein-ipynb-" nil ".ipynb" "{\"cells\": []}"))
             (buffer (find-file-noselect file)))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'ein:ipynb-mode))
              (should-not (derived-mode-p 'prog-mode))
              (should buffer-read-only)
              (should (string-match-p
                       "Opening .*ein-ipynb-.*\\.ipynb as a notebook"
                       (format "%s" (get-char-property (point-min) 'display))))
              ;; The file text itself is untouched.
              (should (equal (buffer-string) "{\"cells\": []}")))
          (kill-buffer buffer)
          (delete-file file))))
    (should-not ran)))

(ert-deftest ein:ipynb-json-when-not-opening ()
  "Without auto-open, or after a failed open, the JSON is shown."
  (ein:testing-ipynb--visiting
    (should-not (get-char-property (point-min) 'display)))
  (let ((ein:ipynb-open-as-notebook t))
    (let* ((file (make-temp-file "ein-ipynb-" nil ".ipynb" "{}"))
           (buffer (find-file-noselect file)))
      (unwind-protect
          (with-current-buffer buffer
            (should (get-char-property (point-min) 'display))
            (cl-letf (((symbol-function 'ein:process-open-notebook)
                       (lambda (&rest _) (user-error "No jupyter"))))
              (ein:ipynb--open buffer))
            (should-not (get-char-property (point-min) 'display)))
        (kill-buffer buffer)
        (delete-file file)))))

(ert-deftest ein:ipynb-edit-json ()
  (ein:testing-ipynb--visiting
    (ein:ipynb-edit-json)
    (should (derived-mode-p 'js-json-mode))
    (should-not buffer-read-only)
    (should-not (get-char-property (point-min) 'display))))

(ert-deftest ein:ipynb-visiting-loads-little ()
  "Visiting an ipynb file, as a `consult' preview does, stays cheap.
The rest of EIN loads only once the file is opened as a notebook."
  (let* ((file (make-temp-file "ein-ipynb-" nil ".ipynb" "{}"))
         (form `(progn
                  (setq load-path ',load-path)
                  (require 'ein-ipynb-mode)
                  (with-current-buffer (find-file-noselect ,file)
                    (princ (format "%s %s %s %s" major-mode
                                   (featurep 'ein-process)
                                   (featurep 'ein-core)
                                   (commandp 'ein:process-find-file-callback))))))
         (output (unwind-protect
                     (with-temp-buffer
                       (call-process (expand-file-name invocation-name
                                                       invocation-directory)
                                     nil t nil "-Q" "--batch" "--eval"
                                     (prin1-to-string form))
                       (buffer-string))
                   (delete-file file))))
    (should (string-match-p "ein:ipynb-mode nil nil t\\'" output))))

(provide 'test-ein-ipynb-mode)
;;; test-ein-ipynb-mode.el ends here
