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

(provide 'test-ein-ipynb-mode)
;;; test-ein-ipynb-mode.el ends here
