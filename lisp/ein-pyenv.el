;;; ein-pyenv.el --- Kernels from Python environments -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; ein-pyenv.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-pyenv.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-pyenv.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Run a notebook's kernel with the Python of any virtual environment
;; or conda environment, as VS Code does, without installing a
;; kernelspec into it.
;;
;; EIN writes a kernelspec for the environment's Python into
;; `ein:pyenv-data-directory', which servers EIN starts read through
;; JUPYTER_PATH.  The session uses that kernel; the notebook's saved
;; metadata names the portable "python3" kernel, so the file still
;; opens on other machines.
;;
;; `ein:select-python-environment' chooses an environment for the
;; current notebook and remembers it for the notebook's file.  A
;; notebook inside a project with a .venv (or venv, env) uses it, after
;; asking once per environment (`ein:pyenv-auto-select').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'ein-core)
(require 'ein-classes)

(declare-function ein:query-kernelspecs "ein-query")
(declare-function ein:jupyter-my-url-or-port "ein-jupyter")
(declare-function ein:jupyter-running-notebook-directory "ein-jupyter")
(declare-function ein:get-notebook "ein-notebook")
(declare-function ein:notebook-switch-kernel "ein-notebook")
(declare-function ein:process-url-match "ein-process")
(declare-function ein:$process-dir "ein-process")
(defvar ein:notebook-session-kernel-functions)

(defgroup ein-pyenv nil
  "Kernels from Python environments."
  :group 'ein)

(defcustom ein:pyenv-data-directory (locate-user-emacs-file "ein/jupyter/")
  "Jupyter data directory private to EIN.
Its kernels/ subdirectory holds the kernelspecs EIN writes for Python
environments.  Servers EIN starts find them through JUPYTER_PATH;
other servers do not."
  :type 'directory)

(defcustom ein:pyenv-auto-select 'ask
  "Whether a notebook inside a project uses the project's environment.
The environment is the nearest directory named in
`ein:pyenv-project-names' above the notebook.  `ask' asks once per
environment, since its Python is a program from the project; t uses
it without asking; nil never does.  A choice made with
`ein:select-python-environment' always wins."
  :type '(choice (const :tag "Ask once per environment" ask)
                 (const :tag "Always" t)
                 (const :tag "Never" nil)))

(defcustom ein:pyenv-project-names '(".venv" "venv" "env")
  "Names of a project's environment directory."
  :type '(repeat string))

(defcustom ein:pyenv-search-patterns
  '("~/.virtualenvs/*" "~/.local/share/virtualenvs/*" "~/.pyenv/versions/*"
    "~/miniconda3" "~/miniconda3/envs/*" "~/anaconda3" "~/anaconda3/envs/*"
    "~/miniforge3" "~/miniforge3/envs/*" "~/mambaforge/envs/*" "~/.conda/envs/*")
  "Wildcards of directories that may be Python environments.
`ein:select-python-environment' offers those with a Python."
  :type '(repeat string))

(defconst ein:pyenv-portable-kernelspec
  '(:name "python3" :display_name "Python 3 (ipykernel)" :language "python")
  "The kernelspec saved in a notebook that runs on an environment's kernel.")

;;; Environments

(defun ein:pyenv-python (env)
  "The Python executable of environment directory ENV, or nil."
  (cl-find-if #'file-executable-p
              (list (expand-file-name "bin/python" env)
                    (expand-file-name "Scripts/python.exe" env))))

(defun ein:pyenv-project-env (filename)
  "The environment directory of the project around FILENAME, or nil.
The nearest one wins."
  (let (best)
    (dolist (name ein:pyenv-project-names)
      (when-let* ((root (locate-dominating-file
                         filename
                         (lambda (dir) (ein:pyenv-python (expand-file-name name dir)))))
                  (env (directory-file-name (expand-file-name name root))))
        (when (or (null best) (> (length env) (length best)))
          (setq best env))))
    best))

(defun ein:pyenv--label (env)
  "How environment directory ENV is shown."
  (format "%s  %s" (file-name-nondirectory env)
          (abbreviate-file-name (file-name-directory env))))

(defun ein:pyenv-environments (&optional filename)
  "Alist (LABEL . PYTHON) of the Python environments EIN can find.
The project environment of FILENAME comes first."
  (let (seen found)
    (cl-flet ((add (env)
                (when-let* ((env (and (stringp env) (not (string-empty-p env))
                                      (directory-file-name (expand-file-name env))))
                            (python (ein:pyenv-python env))
                            (key (file-truename env))
                            ((not (member key seen))))
                  (push key seen)
                  (push (cons (ein:pyenv--label env) python) found))))
      (when filename (add (ein:pyenv-project-env filename)))
      (add (getenv "VIRTUAL_ENV"))
      (add (getenv "CONDA_PREFIX"))
      (add (bound-and-true-p python-shell-virtualenv-root))
      (dolist (pattern ein:pyenv-search-patterns)
        (mapc #'add (file-expand-wildcards (expand-file-name pattern)))))
    (nreverse found)))

;;; Kernelspecs

(defun ein:pyenv-kernel-name (python)
  "Name of the kernel EIN writes for executable PYTHON."
  (concat "ein-venv-" (substring (md5 (expand-file-name python)) 0 12)))

(defun ein:pyenv--display-name (python)
  "Display name of the kernel for PYTHON."
  (let ((env (file-name-directory (directory-file-name (file-name-directory python)))))
    (format "Python (%s)" (abbreviate-file-name (directory-file-name env)))))

(defun ein:pyenv-write-kernelspec (python)
  "Write the kernelspec for PYTHON in `ein:pyenv-data-directory'.
Return its kernel name."
  (let* ((python (expand-file-name python))
         (name (ein:pyenv-kernel-name python))
         (dir (expand-file-name (concat "kernels/" name) ein:pyenv-data-directory))
         (spec `((argv . [,python "-m" "ipykernel_launcher" "-f" "{connection_file}"])
                 (display_name . ,(ein:pyenv--display-name python))
                 (language . "python")
                 (metadata . ((ein_portable
                               . ((name . ,(plist-get ein:pyenv-portable-kernelspec :name))
                                  (display_name . ,(plist-get ein:pyenv-portable-kernelspec
                                                              :display_name))
                                  (language . "python")))))))
         (json-encoding-pretty-print t))
    (with-file-modes #o700 (make-directory dir t))
    (let ((coding-system-for-write 'utf-8-unix))
      (with-temp-file (expand-file-name "kernel.json" dir)
        (insert (json-encode spec) "\n")))
    name))

(defvar ein:pyenv--ipykernel (make-hash-table :test #'equal)
  "Pythons known to have ipykernel.")

(defun ein:pyenv-has-ipykernel-p (python)
  "Non-nil when PYTHON can import ipykernel."
  (or (gethash python ein:pyenv--ipykernel)
      (and (eq 0 (ignore-errors
                   (call-process python nil nil nil "-c" "import ipykernel")))
           (puthash python t ein:pyenv--ipykernel))))

(defun ein:pyenv--with-ipykernel (python then)
  "Call THEN once PYTHON has ipykernel, installing it when the user agrees."
  (cond
   ((ein:pyenv-has-ipykernel-p python) (funcall then))
   ((y-or-n-p (format "%s has no ipykernel.  Install it with pip? "
                      (abbreviate-file-name python)))
    (let ((buffer (get-buffer-create "*ein:pip*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)) (erase-buffer)))
      (message "Installing ipykernel for %s..." (abbreviate-file-name python))
      (make-process
       :name "ein:pip" :buffer buffer :noquery t
       :command (list python "-m" "pip" "install" "ipykernel")
       :sentinel (lambda (proc _event)
                   (unless (process-live-p proc)
                     (if (and (zerop (process-exit-status proc))
                              (ein:pyenv-has-ipykernel-p python))
                         (funcall then)
                       (display-buffer (process-buffer proc))
                       (message "Installing ipykernel failed; see *ein:pip*")))))))
   (t (user-error "%s needs ipykernel to run notebooks"
                  (abbreviate-file-name python)))))

;;; Choices

(defvar ein:pyenv--state nil
  "Alist with `files' (FILE . PYTHON) and `envs' (PYTHON . ALLOWED).")

(defvar ein:pyenv--state-loaded nil)

(defun ein:pyenv--state-file ()
  (expand-file-name "choices.eld" ein:pyenv-data-directory))

(defun ein:pyenv--state (key)
  "The alist under KEY in the remembered choices."
  (unless ein:pyenv--state-loaded
    (setq ein:pyenv--state-loaded t
          ein:pyenv--state
          (ignore-errors
            (with-temp-buffer
              (insert-file-contents (ein:pyenv--state-file))
              (read (current-buffer))))))
  (alist-get key ein:pyenv--state))

(defun ein:pyenv--remember (key item value)
  "Remember VALUE for ITEM under KEY, on disk too."
  (let ((alist (ein:pyenv--state key)))
    (setf (alist-get item alist nil nil #'equal) value)
    (setf (alist-get key ein:pyenv--state) alist))
  (with-file-modes #o700
    (make-directory (file-name-directory (ein:pyenv--state-file)) t))
  (let ((print-length nil) (print-level nil))
    (with-temp-file (ein:pyenv--state-file)
      (prin1 ein:pyenv--state (current-buffer)))))

(defun ein:pyenv--project-allowed-p (python)
  "Whether the project environment's PYTHON may run kernels."
  (pcase ein:pyenv-auto-select
    ('nil nil)
    ('t t)
    (_ (let ((known (assoc python (ein:pyenv--state 'envs))))
         (if known
             (cdr known)
           (let ((allowed (y-or-n-p
                           (format "Run this project's notebooks with %s? "
                                   (abbreviate-file-name python)))))
             (ein:pyenv--remember 'envs python allowed)
             allowed))))))

(defun ein:pyenv-python-for (filename)
  "The Python FILENAME's kernel should use, or nil for the server's default.
Return (PYTHON . EXPLICIT), EXPLICIT when the user chose it."
  (let ((chosen (cdr (assoc (expand-file-name filename) (ein:pyenv--state 'files)))))
    (cond
     ((and chosen (file-executable-p chosen)) (cons chosen t))
     ((when-let* ((env (ein:pyenv-project-env filename))
                  (python (ein:pyenv-python env))
                  ((ein:pyenv--project-allowed-p python)))
        (cons python nil))))))

;;; Opening notebooks

(defvar ein:pyenv--sessions (make-hash-table :test #'equal)
  "(URL-OR-PORT . PATH) to (KERNEL-NAME . EXPLICIT).")

(defun ein:pyenv--session-kernel (notebook)
  "The environment kernel prepared for NOTEBOOK, or nil.
A project environment is not used for a notebook in another language."
  (when-let* ((entry (gethash (cons (ein:$notebook-url-or-port notebook)
                                    (ein:$notebook-notebook-path notebook))
                              ein:pyenv--sessions)))
    (let ((kernelspec (ein:$notebook-kernelspec notebook)))
      (unless (and (not (cdr entry)) kernelspec
                   (not (equal (ein:$kernelspec-language kernelspec) "python")))
        (car entry)))))

(add-hook 'ein:notebook-session-kernel-functions #'ein:pyenv--session-kernel)

(defun ein:pyenv-prepare (filename url-or-port path callback)
  "Arrange for notebook PATH on URL-OR-PORT, the file FILENAME, to start
on its environment's kernel, then call CALLBACK with no arguments.
Without an environment, or one without ipykernel, just call CALLBACK."
  (pcase (and filename (ein:pyenv-python-for filename))
    (`(,python . ,explicit)
     (if (not (ein:pyenv-has-ipykernel-p python))
         (progn
           (message "%s has no ipykernel; using the default kernel (M-x ein:select-python-environment)"
                    (abbreviate-file-name python))
           (funcall callback))
       (puthash (cons url-or-port path)
                (cons (ein:pyenv-write-kernelspec python) explicit)
                ein:pyenv--sessions)
       (ein:query-kernelspecs url-or-port callback)))
    (_ (funcall callback))))

;;; Choosing

(defun ein:pyenv--notebook-file (notebook)
  "The local file of NOTEBOOK, when its server is local."
  (let ((url-or-port (ein:$notebook-url-or-port notebook))
        (path (ein:$notebook-notebook-path notebook)))
    (when-let* ((dir (cond
                      ((and (fboundp 'ein:jupyter-my-url-or-port)
                            (equal url-or-port (ein:jupyter-my-url-or-port)))
                       (ein:jupyter-running-notebook-directory))
                      ((fboundp 'ein:process-url-match)
                       (when-let* ((proc (ignore-errors (ein:process-url-match url-or-port))))
                         (ein:$process-dir proc))))))
      (expand-file-name path dir))))

(defun ein:pyenv-read-python (&optional filename)
  "Read a Python executable, offering the environments around FILENAME."
  (let* ((envs (ein:pyenv-environments filename))
         (other "Other Python executable...")
         (choice (completing-read "Python environment: "
                                  (append (mapcar #'car envs) (list other))
                                  nil t)))
    (if (equal choice other)
        (expand-file-name (read-file-name "Python executable: " nil nil t nil
                                          #'file-executable-p))
      (cdr (assoc choice envs)))))

(defun ein:pyenv-use-python (notebook python)
  "Run NOTEBOOK's kernel with PYTHON from now on."
  (let ((python (expand-file-name python))
        (url-or-port (ein:$notebook-url-or-port notebook))
        (path (ein:$notebook-notebook-path notebook))
        (file (ein:pyenv--notebook-file notebook)))
    (ein:pyenv--with-ipykernel
     python
     (lambda ()
       (let ((name (ein:pyenv-write-kernelspec python)))
         (when file (ein:pyenv--remember 'files file python))
         (puthash (cons url-or-port path) (cons name t) ein:pyenv--sessions)
         (ein:query-kernelspecs
          url-or-port
          (lambda ()
            (if (ein:get-kernelspec url-or-port name)
                (ein:notebook-switch-kernel notebook name)
              (message "%s did not start from EIN, so it cannot see environment kernels; \
`M-x ein:stop' it and reopen the notebook" url-or-port)))))))))

;;;###autoload
(defun ein:select-python-environment (python)
  "Run the current notebook's kernel with the Python of an environment.
Offers the project's .venv, the active virtualenv and conda
environments, and any Python executable.  The choice is remembered
for the notebook's file; the notebook itself keeps naming the
portable python3 kernel."
  (interactive
   (let ((notebook (or (ein:get-notebook) (user-error "Not in a notebook"))))
     (list (ein:pyenv-read-python (ein:pyenv--notebook-file notebook)))))
  (ein:pyenv-use-python (or (ein:get-notebook) (user-error "Not in a notebook"))
                        python))

(provide 'ein-pyenv)

;;; ein-pyenv.el ends here
