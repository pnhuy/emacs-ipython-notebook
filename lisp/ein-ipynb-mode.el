;;; ein-ipynb-mode.el --- A simple mode for ipynb file    -*- lexical-binding:t -*-

;; Copyright (C) 2012 Takafumi Arakaki

;; Author: Takafumi Arakaki <aka.tkf at gmail.com>

;; This file is NOT part of GNU Emacs.

;; ein-ipynb-mode.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-ipynb-mode.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-ipynb-mode.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'js)

;; Visiting an ipynb file (a `consult' preview does that too) must stay
;; cheap: the rest of EIN loads when the file is opened as a notebook.
(autoload 'ein:process-open-notebook "ein-process")
(autoload 'ein:process-find-file-callback "ein-process"
  "Open this ipynb file as a notebook." t)
(autoload 'ein:gat-run-remote "ein-gat"
  "Run this notebook remotely." t)

(defcustom ein:ipynb-open-as-notebook t
  "Non-nil means visiting an ipynb file opens it as a notebook.
As in VS Code, the file opens where it is, on a Jupyter server EIN
starts when needed (see `ein:open').  It happens when the file's
buffer is shown in the selected window, so `find-file-noselect' and
previews while the minibuffer is active do not start servers.  Until
then the buffer shows a placeholder, not the JSON, and runs no code
mode hooks (no eglot for a file about to become a notebook).
\\[ein:ipynb-edit-json] edits the JSON; with this nil, the JSON is
shown read-only."
  :type 'boolean
  :group 'ein)

(defvar-local ein:ipynb--auto-opened nil
  "Non-nil once this buffer was opened as a notebook automatically.")
(put 'ein:ipynb--auto-opened 'permanent-local t)

(defun ein:ipynb--auto-open-p (buffer)
  "Non-nil when BUFFER should now be opened as a notebook."
  (and ein:ipynb-open-as-notebook
       (not noninteractive)
       (buffer-live-p buffer)
       (eq (window-buffer (selected-window)) buffer)
       (not (active-minibuffer-window))
       (with-current-buffer buffer
         (and (derived-mode-p 'ein:ipynb-mode)
              (not ein:ipynb--auto-opened)
              buffer-file-name
              (not (file-remote-p buffer-file-name))
              (not (buffer-modified-p))))))

(defun ein:ipynb--open (buffer)
  "Open BUFFER's file as a notebook; on failure, leave BUFFER as is."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (condition-case err
          (ein:process-open-notebook buffer-file-name #'kill-buffer-if-not-modified)
        (error (ein:ipynb--hide-json nil)
               (message "Showing %s as JSON: %s"
                        (file-name-nondirectory buffer-file-name)
                        (error-message-string err)))))))

(defvar-local ein:ipynb--placeholder nil
  "Overlay showing a placeholder instead of the JSON.")

(defun ein:ipynb--hide-json (hide)
  "Show a placeholder instead of the JSON when HIDE, else the JSON."
  (when ein:ipynb--placeholder
    (delete-overlay ein:ipynb--placeholder)
    (setq ein:ipynb--placeholder nil))
  (when hide
    (let ((ov (make-overlay (point-min) (point-max) nil nil t)))
      (overlay-put ov 'display
                   (substitute-command-keys
                    (format "Opening %s as a notebook...\n\n\
\\<ein:ipynb-mode-map>\\[ein:ipynb-edit-json] edits the JSON instead.\n"
                            (file-name-nondirectory buffer-file-name))))
      (overlay-put ov 'face 'shadow)
      (setq ein:ipynb--placeholder ov))))

(defun ein:ipynb-edit-json ()
  "Edit this ipynb file as JSON instead of opening it as a notebook."
  (interactive)
  (setq ein:ipynb--auto-opened t)
  (ein:ipynb--hide-json nil)
  (js-json-mode)
  (setq buffer-read-only (not (file-writable-p buffer-file-name))))

(defun ein:ipynb--maybe-open (window)
  "Open the buffer of WINDOW as a notebook if it is time to."
  (let ((buffer (window-buffer window)))
    (when (ein:ipynb--auto-open-p buffer)
      (with-current-buffer buffer
        (setq ein:ipynb--auto-opened t))
      (run-at-time 0 nil #'ein:ipynb--open buffer))))

;;;###autoload
(define-derived-mode ein:ipynb-mode special-mode "ein:ipynb"
  "Mode for an ipynb file about to open as a notebook.
It is not a code mode, so code mode hooks (eglot, linters) do not
run.  See `ein:ipynb-open-as-notebook'.

\\{ein:ipynb-mode-map}
"
  :group 'ein
  (ein:ipynb--hide-json (and ein:ipynb-open-as-notebook
                             buffer-file-name
                             (not (file-remote-p buffer-file-name))
                             (not ein:ipynb--auto-opened)))
  (add-hook 'window-buffer-change-functions #'ein:ipynb--maybe-open nil t)
  (add-hook 'window-selection-change-functions #'ein:ipynb--maybe-open nil t)
  :after-hook
  (let* ((filename (file-name-nondirectory buffer-file-truename))
         (remote-filename (concat (file-name-as-directory "run-remote") filename)))
    ;; fragile hack to refresh s3fuse
    (when (file-directory-p "run-remote")
      (call-process "cat" nil nil nil remote-filename))
    (when (and (file-readable-p remote-filename)
               (file-newer-than-file-p remote-filename filename)
               (prog1
                   (let ((inhibit-quit t))
                     (prog1
                         (with-local-quit
                           (y-or-n-p "Corresponding run-remote is newer. Replace? (will first backup) "))
                       (setq quit-flag nil)))
                 (message "")))
      (if-let* ((make-backup-files t)
               (where-to (funcall make-backup-file-name-function buffer-file-name)))
          (let* (backup-inhibited
                 (orig-hooks find-file-hook)
                 (reassure (lambda ()
                             (message "Backed up to %s" where-to)
                             (setq find-file-hook orig-hooks))))
            (backup-buffer)
            (copy-file remote-filename filename t t)
            (add-hook 'find-file-hook reassure nil)
            (find-file-noselect filename t))
        (message "Backup failed.  Not replaced")))))

(let ((map ein:ipynb-mode-map))
  (define-key map "\C-c\C-j" 'ein:ipynb-edit-json)
  (define-key map "\C-c\C-z" 'ein:process-find-file-callback)
  (define-key map "\C-c\C-o" 'ein:process-find-file-callback)
  (define-key map "\C-c\C-r" 'ein:gat-run-remote)
  (easy-menu-define ein:ipynb-menu map "EIN IPyNB Mode Menu"
    '("EIN IPyNB File"
      ["Open notebook" ein:process-find-file-callback
       :help "Open this ipynb file as a notebook."]
      ["Edit JSON" ein:ipynb-edit-json
       :help "Edit this ipynb file as JSON."])))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ipynb\\'" . ein:ipynb-mode))

(provide 'ein-ipynb-mode)

;;; ein-ipynb-mode.el ends here
