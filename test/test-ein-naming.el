;;; test-ein-naming.el --- Notebook buffer names and server ports -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Code:

(require 'ert)
(require 'ein-testing-notebook)
(require 'ein-jupyter)

(defun ein:testing-kill-buffer-quietly (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer (set-buffer-modified-p nil))
    (let ((kill-buffer-query-functions nil)
          (ein:notebook-kill-buffer-ask nil))
      (ignore-errors (kill-buffer buffer)))))

(ert-deftest ein:naming-buffer-is-file-name ()
  (let ((buffer (ein:testing-notebook-make-empty "Untitled.ipynb" "dir/sub/Untitled.ipynb")))
    (unwind-protect
        (should (equal (buffer-name buffer) "Untitled.ipynb"))
      (ein:testing-kill-buffer-quietly buffer))))

(ert-deftest ein:naming-same-file-name-unique ()
  "Notebooks with the same file name in different folders get distinct
buffers; a notebook takes its plain name once that name is free."
  (let* ((raw (get-buffer-create "a.ipynb"))
         (one (ein:testing-notebook-make-empty "a.ipynb" "x/a.ipynb"))
         (two (ein:testing-notebook-make-empty "a.ipynb" "y/a.ipynb")))
    (unwind-protect
        (progn
          (should-not (eq one two))
          (should (string-prefix-p "a.ipynb<" (buffer-name one)))
          (should (string-prefix-p "a.ipynb<" (buffer-name two)))
          (kill-buffer raw)
          (with-current-buffer one
            (mapc #'ein:worksheet-set-buffer-name
                  (ein:$notebook-worksheets ein:%notebook%)))
          (should (equal (buffer-name one) "a.ipynb"))
          (with-current-buffer two
            (mapc #'ein:worksheet-set-buffer-name
                  (ein:$notebook-worksheets ein:%notebook%)))
          (should (string-prefix-p "a.ipynb<" (buffer-name two))))
      (when (buffer-live-p raw) (kill-buffer raw))
      (ein:testing-kill-buffer-quietly one)
      (ein:testing-kill-buffer-quietly two))))

(ert-deftest ein:naming-random-free-port ()
  (let ((ein:jupyter-server-port-range '(10000 . 10010))
        (seen nil))
    (dotimes (_ 20)
      (let ((port (ein:jupyter--free-port)))
        (should (<= 10000 port 10010))
        (push port seen)))
    ;; A port in use is never returned.
    (let ((busy (make-network-process :name "ein-busy" :server t :host "127.0.0.1"
                                      :service 10020 :noquery t)))
      (unwind-protect
          (let ((ein:jupyter-server-port-range '(10020 . 10021)))
            (dotimes (_ 10) (should (= (ein:jupyter--free-port) 10021))))
        (delete-process busy)))))

(ert-deftest ein:naming-server-start-port-args ()
  "Without a port, the server gets a random port above 10000; with one,
exactly that port."
  (let (args)
    (cl-letf (((symbol-function 'ein:jupyter-server-process) #'ignore)
              ((symbol-function 'ein:jupyter-server--run)
               (lambda (_buf _cmd _dir a) (setq args a) nil))
              ((symbol-function 'ein:jupyter--wait-until-ready) #'ignore)
              ((symbol-function 'ein:log-wrapper) #'ignore))
      (ignore-errors (ein:jupyter-server-start "jupyter" "/tmp" t))
      (should (equal (car args) "--port"))
      (should (>= (string-to-number (cadr args)) 10000))
      (should-not (member "--port-retries" args))
      (ignore-errors (ein:jupyter-server-start "jupyter" "/tmp" t nil 9999 '("--x")))
      (should (equal args '("--port" "9999" "--port-retries" "0" "--x")))
      (let ((ein:jupyter-server-port-range nil))
        (ignore-errors (ein:jupyter-server-start "jupyter" "/tmp" t))
        (should-not (member "--port" args))))))

(provide 'test-ein-naming)
;;; test-ein-naming.el ends here
