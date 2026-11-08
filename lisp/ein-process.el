;;; ein-process.el --- Notebook list buffer    -*- lexical-binding:t -*-

;; Copyright (C) 2018- John M. Miller

;; Authors: Takafumi Arakaki <aka.tkf at gmail.com>
;;          John M. Miller <millejoh at mac.com>

;; This file is NOT part of GNU Emacs.

;; ein-process.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-process.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-process.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:


;;; Code:

(require 'ein-jupyter)
(require 'ein-pyenv)

(defcustom ein:process-jupyter-regexp "\\(jupyter\\|ipython\\)\\(-\\|\\s-+\\)note"
  "Regexp by which we recognize notebook servers."
  :type 'string
  :group 'ein)

(defcustom ein:process-lsof "lsof"
  "Executable for lsof command."
  :type 'string
  :group 'ein)

(defun ein:process-divine-dir (pid args &optional error-buffer)
  "Returns notebook-dir or cwd of PID.  Supply ERROR-BUFFER to capture stderr"
  (if (string-match "\\bnotebook-dir\\(=\\|\\s-+\\)\\(\\S-+\\)" args)
      (directory-file-name (match-string 2 args))
    (if (executable-find ein:process-lsof)
        (ein:trim-right
         (with-output-to-string
           (shell-command (format "%s -p %d -a -d cwd -Fn | grep ^n | tail -c +2"
                                  ein:process-lsof pid)
                          standard-output error-buffer))))))

(defun ein:process-divine-port (pid args &optional error-buffer)
  "Returns port on which PID is listening or 0 if none.
Supply ERROR-BUFFER to capture stderr."
  (if (string-match "\\bport\\(=\\|\\s-+\\)\\(\\S-+\\)" args)
      (string-to-number (match-string 2 args))
    (if (executable-find ein:process-lsof)
        (string-to-number
         (ein:trim-right
          (with-output-to-string
            (shell-command (format "%s -p %d -a -iTCP -sTCP:LISTEN -Fn | grep ^n | sed \"s/[^0-9]//g\""
                                   ein:process-lsof pid)
                           standard-output error-buffer)))))))

(defun ein:process-divine-ip (_pid args)
  "Returns notebook-ip of PID"
  (if (string-match "\\bip\\(=\\|\\s-+\\)\\(\\S-+\\)" args)
      (match-string 2 args)
    ein:url-localhost))

(defcustom ein:process-jupyter-regexp "\\(jupyter\\|ipython\\)\\(-\\|\\s-+\\)note"
  "Regexp by which we recognize notebook servers."
  :type 'string
  :group 'ein)


(defcustom ein:process-lsof "lsof"
  "Executable for lsof command."
  :type 'string
  :group 'ein)

(cl-defstruct ein:$process
  "Hold process variables.

`ein:$process-pid' : integer
  PID.

`ein:$process-url': string
  URL

`ein:$process-dir' : string
  Arg of --notebook-dir or 'readlink -e /proc/<pid>/cwd'."
  pid
  url
  dir
)

(ein:deflocal ein:%processes% (make-hash-table :test #'equal)
  "Process table of `ein:$process' keyed on dir.")

(defun ein:process-processes ()
  (hash-table-values ein:%processes%))

(defun ein:process-alive-p (proc)
  (process-attributes (ein:$process-pid proc)))

(defun ein:process-suitable-notebook-dir (filename)
  "Return the uppermost parent dir of DIR that contains ipynb files."
  (let ((fn (expand-file-name filename)))
    (cl-loop with directory = (directory-file-name
                            (if (file-regular-p fn)
                                (file-name-directory (directory-file-name fn))
                              fn))
          with suitable = directory
          until (string= (file-name-nondirectory directory) "")
          do (if (directory-files directory nil "\\.ipynb$")
                 (setq suitable directory))
          (setq directory (directory-file-name (file-name-directory directory)))
          finally return suitable)))

(defun ein:process-refresh-processes ()
  "Use `jupyter notebook list --json` to populate ein:%processes%"
  (clrhash ein:%processes%)
  (cl-loop for line in (condition-case err
                           (apply #'process-lines
                                  ein:jupyter-server-command
                                  (append (ein:jupyter--subcommand-args)
                                          '("list" "--json")))
                         ;; often there is no local jupyter installation
                         (error (ein:log 'info "ein:process-refresh-processes: %s" err) nil))
           do (cl-destructuring-bind
                  (&key pid url root_dir notebook_dir &allow-other-keys)
                  (ein:json-read-from-string line)
                ;; jupyter_server 2.x reports root_dir; notebook < 7 notebook_dir.
                (if-let* ((dir (or root_dir notebook_dir)))
                    (puthash (directory-file-name dir)
                             (make-ein:$process :pid pid
                                                :url (ein:url url)
                                                :dir (directory-file-name dir))
                             ein:%processes%)
                  (ein:log 'warn "ein:process-refresh-processes: server pid %s has no root_dir"
                           pid)))))

(defun ein:process--in-dir-p (filename dir)
  "Non-nil when FILENAME lies under directory DIR."
  (string-prefix-p (file-name-as-directory (expand-file-name dir))
                   (expand-file-name filename)))

(defun ein:process-dir-match (filename)
  "Return the ein:process whose root contains FILENAME.
When several do, the one with the deepest root."
  (let (best)
    (dolist (dir (hash-table-keys ein:%processes%))
      (when (and (ein:process--in-dir-p filename dir)
                 (or (null best) (> (length dir) (length best))))
        (setq best dir)))
    (and best (gethash best ein:%processes%))))

(defsubst ein:process-url-or-port (proc)
  "Naively construct url-or-port from ein:process PROC's port and ip fields"
  (ein:$process-url proc))

(defun ein:process-url-match (url-or-port)
  "Return ein:process whose url matches URL-OR-PORT."
  (cl-loop with parsed-url-or-port = (url-generic-parse-url url-or-port)
        for proc in (ein:process-processes)
        for parsed-url-proc = (url-generic-parse-url (ein:process-url-or-port proc))
        when (and (string= (url-host parsed-url-or-port) (url-host parsed-url-proc))
                  (= (url-port parsed-url-or-port) (url-port parsed-url-proc)))
        return proc))

(defsubst ein:process-path (proc filename)
  "Construct path by eliding PROC's dir from filename."
  (cl-subseq filename (length (file-name-as-directory (ein:$process-dir proc)))))

(defun ein:process--root-path (root filename)
  "FILENAME as a contents path relative to server ROOT."
  (substring (expand-file-name filename)
             (length (file-name-as-directory (expand-file-name root)))))

(defconst ein:process-empty-notebook
  "{\n \"cells\": [\n  {\n   \"cell_type\": \"code\",\n   \"execution_count\": null,\n   \"id\": \"%s\",\n   \"metadata\": {},\n   \"outputs\": [],\n   \"source\": \"\"\n  }\n ],\n \"metadata\": {},\n \"nbformat\": 4,\n \"nbformat_minor\": 5\n}\n"
  "Contents written to a new notebook file: one empty code cell.
%s is the cell id.")

(defun ein:process--ensure-notebook-file (filename)
  "Give FILENAME the contents of a new notebook when it has none.
Never touches a file that has contents."
  (unless (and (file-exists-p filename)
               (> (or (file-attribute-size (file-attributes filename)) 0) 0))
    (make-directory (file-name-directory filename) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (format ein:process-empty-notebook (format "%08x" (random #x100000000)))
                    nil filename nil 'silent))))

(defun ein:process--open (url-or-port path filename callback no-pop)
  "Open notebook PATH on URL-OR-PORT, for local FILENAME.
Kernels from FILENAME's Python environment are arranged first."
  (ein:pyenv-prepare filename url-or-port path
                     (lambda ()
                       (ein:notebook-open url-or-port path nil callback nil no-pop))))

(defun ein:process-open-notebook* (filename callback &optional no-pop)
  "Open FILENAME as a notebook and start a notebook server if necessary.
A running server whose root contains FILENAME is reused.  Otherwise
EIN starts its own server at `ein:jupyter-implicit-root'.  No
notebook list is shown.  CALLBACK with arity 2 (passed into
`ein:notebook-open--callback').  NO-POP leaves showing the notebook
to CALLBACK."
  (ein:process-refresh-processes)
  (let* ((proc (or (ein:process-dir-match filename)
                   (when-let* ((true (file-truename filename))
                               ((not (equal true filename)))
                               (proc (ein:process-dir-match true)))
                     (setq filename true)
                     proc))))
    (cond
     (proc
      (let* ((url-or-port (ein:process-url-or-port proc))
             (path (ein:process-path proc filename)))
        (if (ein:notebooklist-list-get url-or-port)
            (ein:process--open url-or-port path filename callback no-pop)
          (ein:notebooklist-login
           url-or-port
           (lambda (_buffer url-or-port)
             (ein:process--open url-or-port path filename callback no-pop))))))
     ((and (not ein:jupyter-use-containers) (ein:jupyter-server-process))
      (user-error "%s is outside %s, the root of EIN's server; `M-x ein:stop' it first"
                  filename (ein:jupyter-running-notebook-directory)))
     ((not ein:jupyter-use-containers)
      (let* ((root (expand-file-name ein:jupyter-implicit-root))
             (path (ein:process--root-path root filename)))
        (unless (ein:process--in-dir-p filename root)
          (user-error "%s is outside `ein:jupyter-implicit-root' (%s)" filename root))
        (message "Starting a Jupyter server for %s..." (file-name-nondirectory filename))
        (ein:jupyter-server-start (executable-find ein:jupyter-server-command)
                                  root nil
                                  (lambda (_buffer url-or-port)
                                    (ein:process--open url-or-port path filename callback no-pop))
                                  nil ein:jupyter-implicit-server-args)))
     (t
      (let* ((nbdir (read-directory-name "Notebook directory: "
                                         (ein:process-suitable-notebook-dir filename)))
             (path
              (concat (if ein:jupyter-use-containers
                          (file-name-as-directory (file-name-base ein:jupyter-docker-mount-point))
                        "")
                      (cl-subseq (expand-file-name filename)
                                 (length (file-name-as-directory (expand-file-name nbdir))))))
             (callback2 (apply-partially (lambda (path* callback* buffer url-or-port)
                                           (ein:show-buffer buffer)
                                           (ein:notebook-open url-or-port
                                                              path* nil callback*))
                                         path callback)))
        (ein:jupyter-server-start (executable-find ein:jupyter-server-command)
                                  nbdir nil callback2))))))

(defun ein:process--show-notebook (raw notebook)
  "Show NOTEBOOK in the windows showing RAW, the buffer visiting its file.
Show it in the selected window when no window shows RAW."
  (let ((buffer (ein:notebook-buffer notebook))
        (windows (and (buffer-live-p raw) (get-buffer-window-list raw nil t))))
    (if windows
        (dolist (window windows)
          (set-window-buffer window buffer))
      (ein:show-buffer buffer))))

(defun ein:process-open-notebook (&optional filename buffer-callback)
  "Open FILENAME as a notebook.
When FILENAME is unspecified the variable `buffer-file-name' is used
instead.  A missing or empty FILENAME becomes a new notebook.
When the current buffer visits FILENAME, the notebook takes its
windows.  BUFFER-CALLBACK is then called with that buffer."
  (interactive)
  (unless filename (setq filename buffer-file-name))
  (cl-assert filename nil "Not visiting a file")
  (when (file-remote-p filename)
    (user-error "Remote notebooks open through `ein:login' to their server"))
  (let* ((filename (expand-file-name filename))
         (raw (and buffer-file-name
                   (equal (expand-file-name buffer-file-name) filename)
                   (current-buffer))))
    (ein:process--ensure-notebook-file filename)
    (ein:process-open-notebook*
     filename
     (lambda (notebook _created &rest _args)
       (when raw
         (ein:process--show-notebook raw notebook)
         (when (and buffer-callback (buffer-live-p raw))
           (funcall buffer-callback raw))
         ;; RAW held the file name; take it once RAW is gone.
         (unless (buffer-live-p raw)
           (mapc #'ein:worksheet-set-buffer-name
                 (ein:$notebook-worksheets notebook)))))
     raw)))

(defun ein:process-find-file-callback ()
  "Open the ipynb file of the current buffer as a notebook."
  (interactive)
  (-when-let* ((filename buffer-file-name)
               (match-p (string-match-p "\\.ipynb$" filename)))
    (ein:process-open-notebook filename #'kill-buffer-if-not-modified)))

;;;###autoload
(defun ein:open (filename)
  "Open the notebook FILENAME, wherever it is.
Like opening a notebook in VS Code: there is no root to choose and
no notebook list.  A Jupyter server is started when none can open
FILENAME.  A new file name creates a new notebook."
  (interactive
   (list (read-file-name "Open notebook: " nil nil nil nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-suffix-p ".ipynb" f))))))
  (let ((filename (expand-file-name filename)))
    (unless (string-suffix-p ".ipynb" filename)
      (setq filename (concat filename ".ipynb")))
    (if-let* ((buffer (find-buffer-visiting filename)))
        (with-current-buffer buffer
          (ein:process-open-notebook filename #'kill-buffer-if-not-modified))
      (ein:process-open-notebook filename))))

(provide 'ein-process)

;;; ein-process.el ends here
