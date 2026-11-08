;;; test-ein-windows.el --- Main EIN buffers open full -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; The notebook list, notebooks and server files open in the selected
;; window, as `find-file' does, instead of splitting the frame.

;;; Code:

(require 'ert)
(require 'ein-notebooklist)
(require 'ein-notebook)
(require 'ein-file)

(defmacro ein:testing-windows--shows-full (buffer &rest body)
  "Run BODY in a one-window frame that splits whenever it can.
Then BUFFER must fill the frame, in the selected window."
  (declare (indent 1))
  `(save-window-excursion
     (delete-other-windows)
     (switch-to-buffer "*scratch*")
     (let ((split-height-threshold 0)
           (split-width-threshold 0)
           (pop-up-windows t)
           (display-buffer-alist nil))
       ,@body
       (should (= 1 (length (window-list))))
       (should (eq (window-buffer (selected-window)) ,buffer)))))

(ert-deftest ein:windows-show-buffer ()
  (let ((buffer (generate-new-buffer "ein-windows")))
    (unwind-protect
        (ein:testing-windows--shows-full buffer
          (ein:show-buffer buffer 8888))
      (kill-buffer buffer))))

(ert-deftest ein:windows-login-shows-list-full ()
  "`ein:login' shows the notebook list in the selected window."
  (let ((buffer (generate-new-buffer "*ein:notebooklist test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'ein:notebooklist-ask-url-or-port)
                   (lambda () 8888)))
          (let* ((current-prefix-arg nil)
                 (args (advice-eval-interactive-spec
                        (cadr (interactive-form 'ein:notebooklist-login)))))
            (ein:testing-windows--shows-full buffer
              (funcall (nth 1 args) buffer 8888))))
      (kill-buffer buffer))))

(ert-deftest ein:windows-notebook-opens-full ()
  "A notebook opened from the list takes the list's window."
  (let ((buffer (generate-new-buffer "nb.ipynb"))
        (notebook (make-ein:$notebook :url-or-port 8888 :notebook-path "nb.ipynb")))
    (unwind-protect
        (cl-letf (((symbol-function 'ein:notebook-buffer) (lambda (_) buffer))
                  ((symbol-function 'ein:worksheet-focus-cell) #'ignore)
                  ((symbol-function 'ein:notebooklist-get-buffer) #'ignore))
          (ein:testing-windows--shows-full buffer
            (funcall (ein:notebook-open--decorate-callback
                      notebook t #'ignore nil nil))))
      (kill-buffer buffer))))

(ert-deftest ein:windows-file-opens-full ()
  (let* ((content (make-ein:$content :url-or-port 8888 :path "a.txt"
                                     :name "a.txt" :raw-content "hi"))
         (find (lambda ()
                 (seq-find (lambda (b)
                             (eq (buffer-local-value 'ein:content-file-buffer--content b)
                                 content))
                           (buffer-list)))))
    (unwind-protect
        (ein:testing-windows--shows-full (funcall find)
          (ein:file-open-finish content))
      (when-let* ((buffer (funcall find)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(provide 'test-ein-windows)
;;; test-ein-windows.el ends here
