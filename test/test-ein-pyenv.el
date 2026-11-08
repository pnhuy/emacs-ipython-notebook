;;; test-ein-pyenv.el --- Kernels from Python environments -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Code:

(require 'ert)
(require 'ein-pyenv)
(require 'ein-jupyter)
(require 'ein-notebook)
(require 'ein-nbview-toolbar)

(defun ein:testing-pyenv--python (env &optional status)
  "Make ENV a fake environment whose python exits with STATUS."
  (let ((python (expand-file-name "bin/python" env)))
    (make-directory (file-name-directory python) t)
    (with-temp-file python (insert (format "#!/bin/sh\nexit %d\n" (or status 0))))
    (set-file-modes python #o755)
    python))

(defmacro ein:testing-pyenv--sandbox (&rest body)
  "Run BODY with `root' a temporary directory and fresh EIN choices."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "ein-pyenv-" t))))
          (ein:pyenv-data-directory (expand-file-name "data/" root))
          (ein:pyenv--state nil)
          (ein:pyenv--state-loaded nil)
          (ein:pyenv--ipykernel (make-hash-table :test #'equal))
          (ein:pyenv--sessions (make-hash-table :test #'equal)))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(ert-deftest ein:pyenv-project-env-nearest ()
  (ein:testing-pyenv--sandbox
    (ein:testing-pyenv--python (expand-file-name "proj/.venv" root))
    (ein:testing-pyenv--python (expand-file-name "proj/sub/venv" root))
    (make-directory (expand-file-name "proj/other" root) t)
    (should (equal (ein:pyenv-project-env (expand-file-name "proj/sub/a.ipynb" root))
                   (expand-file-name "proj/sub/venv" root)))
    (should (equal (ein:pyenv-project-env (expand-file-name "proj/other/a.ipynb" root))
                   (expand-file-name "proj/.venv" root)))
    (should-not (ein:pyenv-project-env (expand-file-name "a.ipynb" root)))))

(ert-deftest ein:pyenv-environments-listed-once ()
  (ein:testing-pyenv--sandbox
    (let* ((venv (expand-file-name "proj/.venv" root))
           (python (ein:testing-pyenv--python venv))
           (ein:pyenv-search-patterns (list (expand-file-name "proj/*" root)
                                            (expand-file-name "envs/*" root)))
           (process-environment (cons (concat "VIRTUAL_ENV=" venv) process-environment)))
      (ein:testing-pyenv--python (expand-file-name "envs/ml" root))
      (make-directory (expand-file-name "envs/empty" root) t)
      (let ((envs (ein:pyenv-environments (expand-file-name "proj/a.ipynb" root))))
        (should (= (length envs) 2))
        (should (equal (cdar envs) python))
        (should (string-prefix-p "ml" (car (nth 1 envs))))))))

(ert-deftest ein:pyenv-kernelspec-file ()
  "The kernel runs the environment's Python and saves as python3."
  (ein:testing-pyenv--sandbox
    (let* ((python (ein:testing-pyenv--python (expand-file-name "proj/.venv" root)))
           (name (ein:pyenv-write-kernelspec python))
           (spec (json-parse-string
                  (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name (format "kernels/%s/kernel.json" name)
                                       ein:pyenv-data-directory))
                    (buffer-string)))))
      (should (string-match-p "\\`ein-venv-[0-9a-f]\\{12\\}\\'" name))
      (should (equal name (ein:pyenv-write-kernelspec python)))
      (should (equal (aref (gethash "argv" spec) 0) python))
      (should (equal (gethash "language" spec) "python"))
      (should (equal (gethash "name" (gethash "ein_portable" (gethash "metadata" spec)))
                     "python3")))))

(ert-deftest ein:pyenv-saved-metadata-portable ()
  (let ((venv (make-ein:$kernelspec
               :name "ein-venv-0123456789ab" :language "python"
               :spec '(:display_name "Python (~/proj/.venv)" :language "python"
                       :metadata (:ein_portable (:name "python3" :display_name "Python 3 (ipykernel)"
                                                 :language "python")))))
        (plain (make-ein:$kernelspec :name "ir" :language "R"
                                     :spec '(:display_name "R" :language "R"))))
    (should (equal (plist-get (ein:notebook--kernelspec-metadata venv) :name) "python3"))
    (should (equal (plist-get (ein:notebook--kernelspec-metadata plain) :name) "ir"))))

(ert-deftest ein:pyenv-choice-order ()
  "A chosen Python wins; a project environment is asked about once."
  (ein:testing-pyenv--sandbox
    (let* ((file (expand-file-name "proj/a.ipynb" root))
           (project (ein:testing-pyenv--python (expand-file-name "proj/.venv" root)))
           (chosen (ein:testing-pyenv--python (expand-file-name "envs/ml" root)))
           (asked 0)
           (answer nil)
           (ein:pyenv-auto-select 'ask))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) (cl-incf asked) answer)))
        (should-not (ein:pyenv-python-for file))
        (should-not (ein:pyenv-python-for file))
        (should (= asked 1))
        ;; Remembered on disk.
        (setq ein:pyenv--state nil ein:pyenv--state-loaded nil)
        (should-not (ein:pyenv-python-for file))
        (should (= asked 1))
        (let ((ein:pyenv-auto-select t))
          (should (equal (ein:pyenv-python-for file) (cons project nil))))
        (ein:pyenv--remember 'files file chosen)
        (should (equal (ein:pyenv-python-for file) (cons chosen t)))))))

(ert-deftest ein:pyenv-prepare-session-kernel ()
  "Preparing writes the kernel, refreshes kernelspecs, and the session
uses it; a project environment is not forced on a non-Python notebook."
  (ein:testing-pyenv--sandbox
    (let* ((file (expand-file-name "proj/a.ipynb" root))
           (python (ein:testing-pyenv--python (expand-file-name "proj/.venv" root)))
           (ein:pyenv-auto-select t)
           refreshed done)
      (cl-letf (((symbol-function 'ein:query-kernelspecs)
                 (lambda (_url callback) (setq refreshed t) (funcall callback))))
        (ein:pyenv-prepare file 8888 "proj/a.ipynb" (lambda () (setq done t))))
      (should (and refreshed done))
      (let ((nb (make-ein:$notebook :url-or-port 8888 :notebook-path "proj/a.ipynb")))
        (should (equal (ein:pyenv--session-kernel nb) (ein:pyenv-kernel-name python)))
        (setf (ein:$notebook-kernelspec nb) (make-ein:$kernelspec :name "ir" :language "R"))
        (should-not (ein:pyenv--session-kernel nb))))))

(ert-deftest ein:pyenv-prepare-without-ipykernel ()
  (ein:testing-pyenv--sandbox
    (ein:testing-pyenv--python (expand-file-name "proj/.venv" root) 1)
    (let ((ein:pyenv-auto-select t) done)
      (cl-letf (((symbol-function 'ein:query-kernelspecs)
                 (lambda (&rest _) (error "Refreshed"))))
        (ein:pyenv-prepare (expand-file-name "proj/a.ipynb" root) 8888 "proj/a.ipynb"
                           (lambda () (setq done t))))
      (should done)
      (should (= (hash-table-count ein:pyenv--sessions) 0)))))

(ert-deftest ein:pyenv-server-sees-kernels ()
  "Servers EIN starts look in EIN's data directory first."
  (let* ((ein:pyenv-data-directory "/tmp/ein-data/")
         (process-environment (cons "JUPYTER_PATH=/opt/j" process-environment)))
    (let ((process-environment (ein:jupyter--process-environment)))
      (should (equal (getenv "JUPYTER_PATH")
                     (concat "/tmp/ein-data" path-separator "/opt/j"))))))

(ert-deftest ein:pyenv-switched-kernel-survives-reopen ()
  "Switching saves the portable kernel, but the reopened session keeps
the chosen one."
  (let* ((ein:notebook--session-kernels (make-hash-table :test #'equal))
         (venv (make-ein:$kernelspec
                :name "ein-venv-0123456789ab" :language "python"
                :spec '(:metadata (:ein_portable (:name "python3" :language "python")))))
         (py3 (make-ein:$kernelspec :name "python3" :language "python" :spec nil))
         (nb (make-ein:$notebook :url-or-port 8888 :notebook-path "a.ipynb"
                                 :kernel (make-ein:$kernel))))
    (cl-letf (((symbol-function 'ein:get-kernelspec)
               (lambda (_url name &rest _) (if (equal name "python3") py3 venv)))
              ((symbol-function 'ein:notebook-save-notebook) #'ignore)
              ((symbol-function 'ein:notebook-open) #'ignore))
      (ein:notebook-switch-kernel nb "ein-venv-0123456789ab")
      (should (equal (plist-get (plist-get (ein:$notebook-metadata nb) :kernelspec) :name)
                     "python3"))
      (let ((reopened (make-ein:$notebook :url-or-port 8888 :notebook-path "a.ipynb"
                                          :kernelspec py3)))
        (ein:notebook--apply-session-kernel reopened)
        (should (eq (ein:$notebook-kernelspec reopened) venv))))))

(ert-deftest ein:pyenv-new-notebook-gets-default-kernel ()
  "A notebook whose metadata names no kernel shows the server's default."
  (let* ((ein:notebook--session-kernels (make-hash-table :test #'equal))
         (ein:notebook-session-kernel-functions nil)
         (py3 (make-ein:$kernelspec :name "python3" :language "python" :spec nil))
         (nb (make-ein:$notebook :url-or-port 8888 :notebook-path "new.ipynb")))
    (cl-letf (((symbol-function 'ein:get-kernelspec)
               (lambda (_url name &rest _) (and (eq name :default) py3))))
      (ein:notebook--apply-session-kernel nb)
      (should (eq (ein:$notebook-kernelspec nb) py3))
      (should (equal (ein:nbview--kernel-name nb) "python3")))))

(ert-deftest ein:pyenv-install-command-pip-or-uv ()
  "uv venvs (and venvs without pip) install ipykernel with uv."
  (let* ((dir (make-temp-file "ein-venv-" t))
         (python (expand-file-name "bin/python" dir))
         (cfg (expand-file-name "pyvenv.cfg" dir))
         (ein:pyenv-uv-command "uv")
         has-pip uv)
    (unwind-protect
        (cl-letf (((symbol-function 'ein:pyenv--has-pip-p) (lambda (_) has-pip))
                  ((symbol-function 'executable-find)
                   (lambda (cmd &rest _) (and uv (equal cmd "uv") "/usr/bin/uv"))))
          (write-region "home = /usr/bin\n" nil cfg nil 'silent)
          (setq has-pip t)
          (should (equal (ein:pyenv-install-command python)
                         (list python "-m" "pip" "install" "ipykernel")))
          ;; No pip: uv when available, else nothing.
          (setq has-pip nil uv t)
          (should (equal (ein:pyenv-install-command python)
                         (list "/usr/bin/uv" "pip" "install" "--python" python "ipykernel")))
          (setq uv nil)
          (should-not (ein:pyenv-install-command python))
          ;; A uv-made venv prefers uv even with pip.
          (write-region "home = /usr/bin\nuv = 0.13.0\n" nil cfg nil 'silent)
          (setq has-pip t uv t)
          (should (equal (car (ein:pyenv-install-command python)) "/usr/bin/uv")))
      (delete-directory dir t))))

(ert-deftest ein:pyenv-with-ipykernel-runs-install-command ()
  (let ((ein:pyenv--ipykernel (make-hash-table :test #'equal))
        command prompt)
    (cl-letf (((symbol-function 'ein:pyenv-has-ipykernel-p) #'ignore)
              ((symbol-function 'ein:pyenv-install-command)
               (lambda (py) (list "/usr/bin/uv" "pip" "install" "--python" py "ipykernel")))
              ((symbol-function 'y-or-n-p) (lambda (p) (setq prompt p) t))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq command (plist-get args :command)) nil)))
      (ein:pyenv--with-ipykernel "/p/.venv/bin/python" #'ignore)
      (should (string-match-p "with uv" prompt))
      (should (equal (car command) "/usr/bin/uv")))
    ;; Without an installer, say how to install it.
    (cl-letf (((symbol-function 'ein:pyenv-has-ipykernel-p) #'ignore)
              ((symbol-function 'ein:pyenv-install-command) #'ignore))
      (should-error (ein:pyenv--with-ipykernel "/p/.venv/bin/python" #'ignore)
                    :type 'user-error))))

(ert-deftest ein:pyenv-switch-kernel-reopens-in-same-window ()
  "The reopened notebook takes the old one's window instead of splitting."
  (let* ((ein:notebook--session-kernels (make-hash-table :test #'equal))
         (old (generate-new-buffer "old.ipynb"))
         (new (generate-new-buffer "new.ipynb"))
         (ks (make-ein:$kernelspec :name "python3" :language "python" :spec nil))
         (nb (make-ein:$notebook :url-or-port 8888 :notebook-path "a.ipynb"
                                 :kernel (make-ein:$kernel)))
         open-args)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer old)
          (cl-letf (((symbol-function 'ein:get-kernelspec) (lambda (&rest _) ks))
                    ((symbol-function 'ein:notebook-buffer)
                     (lambda (n) (if (eq n nb) old new)))
                    ((symbol-function 'ein:notebook-save-notebook)
                     (lambda (&rest _) (switch-to-buffer "*scratch*") (kill-buffer old)))
                    ((symbol-function 'ein:notebook-open)
                     (lambda (&rest args) (setq open-args args)
                       (funcall (nth 3 args) 'reopened nil))))
            (ein:notebook-switch-kernel nb "python3")
            (should (nth 5 open-args))          ; no-pop
            (should (= 1 (length (window-list))))
            (should (eq (window-buffer (selected-window)) new))))
      (mapc (lambda (b) (when (buffer-live-p b) (kill-buffer b))) (list old new)))))

(provide 'test-ein-pyenv)
;;; test-ein-pyenv.el ends here
