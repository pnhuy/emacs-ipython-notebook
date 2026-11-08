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

(provide 'test-ein-pyenv)
;;; test-ein-pyenv.el ends here
