;;; ein-notebook.el --- Notebook module    -*- lexical-binding:t -*-

;; Copyright (C) 2012- Takafumi Arakaki

;; Author: Takafumi Arakaki <aka.tkf at gmail.com>

;; This file is NOT part of GNU Emacs.

;; ein-notebook.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-notebook.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-notebook.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; * Coding rule about current buffer.
;; A lot of notebook and cell functions touches to current buffer and
;; it is not ideal to wrap all these functions by `with-current-buffer'.
;; Therefore, when the function takes `notebook' to the first argument
;; ("method" function), it is always assumed that the current buffer
;; is the notebook buffer.  **However**, functions called as callback
;; (via `url-retrieve', for example) must protect themselves by
;; calling from unknown buffer.

;;; Code:


(require 'ein-node)
(require 'ein-file)
(require 'ein-notebooklist)
(require 'ein-kernelinfo)
(require 'ein-scratchsheet)
(require 'ein-notification)
(require 'ein-completer)
(require 'ein-pager)
(require 'ein-events)
(require 'ein-notification)
(require 'ein-kill-ring)
(require 'ein-query)
(require 'ein-pytools)
(require 'ein-traceback)
(require 'ein-python-send)

(require 'ein-view)

(autoload 'ob-ein-anonymous-p "ob-ein")

;; poly-ein (and polymode) load with the classic view only.  Compile
;; against polymode for its EIEIO slot names.
(eval-when-compile (require 'polymode))
(defvar pm/polymode)
(defvar poly-ein-mode)
(declare-function poly-ein-mode "poly-ein")
(declare-function poly-ein-fontify-buffer "poly-ein")
(declare-function poly-ein-call-in-base "poly-ein")
(declare-function pm-select-buffer "polymode-core")
(declare-function pm-innermost-span "polymode-core")
(declare-function pm-span-buffer "polymode-core")
(declare-function ein:nbview-open "ein-nbview")
(declare-function ein:nbview-toolbar-setup "ein-nbview-toolbar")

(make-obsolete-variable 'ein:use-smartrep nil "0.17.0")

(make-obsolete-variable 'ein:notebook-autosave-frequency nil "0.17.0")

(make-obsolete-variable 'ein:notebook-create-checkpoint-on-save nil "0.17.0")

(make-obsolete-variable 'ein:notebook-discard-output-on-save nil "0.17.0")

(make-obsolete-variable 'ein:notebook-after-rename-hook nil "0.17.0")

(defvar *ein:notebook--pending-query* (make-hash-table :test 'equal)
  "A map: (URL-OR-PORT . PATH) => t/nil")

(defun ein:notebook-cell-has-image-output-p (_ignore cell)
  (ein:cell-has-image-output-p cell))

(defconst ein:notebook-pager-buffer-name-template "*ein:pager %s/%s*")

(define-obsolete-variable-alias 'ein:notebook 'ein:%notebook% "0.1.2")
(ein:deflocal ein:%notebook% nil
  "Buffer local variable to store an instance of `ein:$notebook'.")

(defun ein:get-notebook () ein:%notebook%)

(defun ein:get-notebook-or-error ()
  (or (ein:get-notebook)
      (error "No notebook related to the current buffer.")))

(defun ein:notebook-new (url-or-port notebook-path pre-kernelspec &rest args)
  (let ((kernelspec
         (cond ((ein:$kernelspec-p pre-kernelspec) pre-kernelspec)
               ((consp pre-kernelspec)
                (cl-loop for (_name ks) on (ein:need-kernelspecs url-or-port) by 'cddr
                         when (and (ein:$kernelspec-p ks)
                                   (string= (cdr pre-kernelspec)
                                            (cl-struct-slot-value
                                             'ein:$kernelspec (car pre-kernelspec) ks)))
                         return ks))
               (t (ein:get-kernelspec url-or-port pre-kernelspec)))))
    (apply #'make-ein:$notebook
           :url-or-port url-or-port
           :kernelspec kernelspec
           :notebook-path notebook-path
           args)))

(defun ein:notebook-close-worksheet (notebook ws)
  "Close worksheet WS in NOTEBOOK.

This is problematic as ein:$notebook-worksheets doesn't delq ws.
And I don't know if I can on account of the dont-save-cells nonsense."
  (cl-symbol-macrolet ((scratchsheets (ein:$notebook-scratchsheets notebook)))
    (cond
     ((ein:worksheet-p ws) (ein:worksheet-save-cells ws t))
     (t (setf scratchsheets (delq ws scratchsheets))))))

;;; Notebook utility functions

(defun ein:notebook-buffer (notebook)
  "Return first buffer in NOTEBOOK's worksheets."
  (awhen notebook
    (seq-some #'ein:worksheet-buffer (append (ein:$notebook-worksheets it)
					     (ein:$notebook-scratchsheets it)))))

(defun ein:notebook-buffer-list (notebook)
  "Return the direct and indirect buffers."
  (append
   (cl-remove-if-not
    #'identity
    (cl-mapcan (lambda (ws)
                 (when-let* ((ws-buf (ein:worksheet-buffer ws)))
                   (with-current-buffer ws-buf
                     (mapcar #'buffer-name
                             (if (bound-and-true-p pm/polymode)
                                 (eieio-oref pm/polymode '-buffers)
                               (list ws-buf))))))
               (append (ein:$notebook-worksheets notebook)
                       (ein:$notebook-scratchsheets notebook))))
   (awhen (ein:$notebook-kernel notebook)
     (awhen (ein:ipdb-get-session it)
       (list (ein:$ipdb-session-buffer it))))))

(defun ein:notebook--get-nb-or-error ()
  (or ein:%notebook% (error "Not in notebook buffer.")))

;;;###autoload
(defalias 'ein:notebook-name 'ein:$notebook-notebook-name)

;;; Open notebook

(defsubst ein:notebook-url (notebook)
  (ein:notebooklist-url (ein:$notebook-url-or-port notebook)
                        (ein:$notebook-notebook-path notebook)))

(defsubst ein:notebook--spec-insert-name (name spec)
  "Add kernel NAME, e.g., python2, to the kernelspec member of ipynb metadata."
  (if (plist-member spec :name)
      spec
    (plist-put spec :name name)))

(defun ein:notebook--kernelspec-metadata (kernelspec)
  "The kernelspec member of ipynb metadata for KERNELSPEC.
A kernel EIN made for one machine's Python environment names a
portable kernel instead, so the notebook opens elsewhere."
  (if-let* ((portable (plist-get (plist-get (ein:$kernelspec-spec kernelspec) :metadata)
                                 :ein_portable)))
      (copy-sequence portable)
    (ein:notebook--spec-insert-name (ein:$kernelspec-name kernelspec)
                                    (ein:$kernelspec-spec kernelspec))))

(defvar ein:notebook-session-kernel-functions nil
  "Abnormal hook choosing the kernel a notebook's session starts with.
Each function takes the NOTEBOOK being opened, whose kernelspec comes
from its metadata, and returns a kernel name or nil.  The first name
the server knows wins.  The notebook's metadata is not changed.")

(defvar ein:notebook--session-kernels (make-hash-table :test #'equal)
  "(URL-OR-PORT . PATH) to the kernel chosen with `ein:notebook-switch-kernel'.
Lasts for this Emacs session.")

(defun ein:notebook--apply-session-kernel (notebook)
  "Pick NOTEBOOK's kernel: the one last switched to in this Emacs, else
the first of `ein:notebook-session-kernel-functions'.  A notebook with
no kernel gets the server's default kernel."
  (when-let* ((name (or (gethash (cons (ein:$notebook-url-or-port notebook)
                                       (ein:$notebook-notebook-path notebook))
                                 ein:notebook--session-kernels)
                        (run-hook-with-args-until-success
                         'ein:notebook-session-kernel-functions notebook))))
    (if-let* ((kernelspec (ein:get-kernelspec (ein:$notebook-url-or-port notebook) name)))
        (setf (ein:$notebook-kernelspec notebook) kernelspec)
      (ein:log 'warn "Kernel %s is unknown to %s; keeping the notebook's kernel"
               name (ein:$notebook-url-or-port notebook))))
  ;; A new notebook's metadata names no kernel: use the server's default,
  ;; which is the kernel the server would start anyway.
  (unless (ein:$notebook-kernelspec notebook)
    (setf (ein:$notebook-kernelspec notebook)
          (ein:get-kernelspec (ein:$notebook-url-or-port notebook) :default))))

(defun ein:notebook-open--decorate-callback (notebook existing pending-clear callback no-pop)
  "In addition to CALLBACK,
clear the pending semaphore,
show the new notebook in the selected window,
save to disk the kernelspec metadata,
reload the notebooklist so that \"[Stop]\" shows up,
and put last warning in minibuffer."
  (apply-partially
   (lambda (notebook* created callback* pending-clear* no-pop*)
     (funcall pending-clear*)
     (with-current-buffer (ein:notebook-buffer notebook*)
       ;; The cells view places point itself when rendering.
       (unless (and ein:%worksheet% (ein:worksheet--view ein:%worksheet%))
         (ein:worksheet-focus-cell)))
     (unless no-pop*
       (with-current-buffer (ein:notebook-buffer notebook*)
         (if (bound-and-true-p pm/polymode)
             (progn
               (pm-select-buffer (pm-innermost-span))
               (ein:show-buffer (pm-span-buffer (pm-innermost-span))))
           (ein:show-buffer (current-buffer)))))
     ;; Record the kernel in metadata for the next save, but never
     ;; write to the server merely because the notebook was opened.
     (when (null (plist-member (ein:$notebook-metadata notebook*) :kernelspec))
       (awhen (ein:$notebook-kernelspec notebook*)
         (setf (ein:$notebook-metadata notebook*)
               (plist-put (ein:$notebook-metadata notebook*)
                          :kernelspec (ein:notebook--kernelspec-metadata it)))))
     (when callback*
       (funcall callback* notebook* created))
     (-when-let* ((created created)
                  (buffer (get-buffer "*Warnings*"))
                  (last-warning (with-current-buffer buffer
                                  (thing-at-point 'line t))))
       (message "%s" last-warning))
     (aif (ein:notebooklist-get-buffer (ein:$notebook-url-or-port notebook*))
         (ein:notebooklist-reload (buffer-local-value 'ein:%notebooklist% it))))
   notebook (not existing) callback pending-clear no-pop))

(defun ein:notebook-open-or-create (url-or-port path &optional kernelspec callback no-pop)
  "Same as `ein:notebook-open' but create PATH if not found."
  (let ((if-not-found (lambda (_contents _status-code) )))
    (ein:notebook-open url-or-port path kernelspec callback if-not-found no-pop)))

;;;###autoload
(defun ein:notebook-jump-to-opened-notebook (notebook)
  "List all opened notebook buffers and switch to one that the user selects."
  (interactive
   (list (completing-read "Jump to notebook:" (ein:notebook-opened-buffer-names) nil t)))
  (switch-to-buffer notebook))

;;;###autoload
(defun ein:notebook-open (url-or-port path
                          &optional kernelspec callback errback no-pop)
  "Returns notebook at URL-OR-PORT/PATH.

Note that notebook sends for its contents and won't have them right away.

After the notebook is opened, CALLBACK is called as::

  \(funcall CALLBACK notebook created)

where `created' indicates a new notebook or an existing one."
  (interactive
   (ein:notebooklist-parse-nbpath (ein:notebooklist-ask-path "notebook")))
  (unless errback (setq errback #'ignore))
  (let* ((pending-key (cons url-or-port path))
         (pending-p (gethash pending-key *ein:notebook--pending-query*))
         (pending-clear (apply-partially (lambda (pending-key* &rest _args)
                                           (remhash pending-key*
                                                    *ein:notebook--pending-query*))
                                         pending-key))
         (existing (ein:notebook--live-opened-notebook url-or-port path))
         (notebook (aif existing it
                     (ein:notebook-new url-or-port path kernelspec)))
         (callback0 (ein:notebook-open--decorate-callback notebook existing pending-clear
                                                          callback no-pop)))
    (if existing
        (progn
          (ein:log 'info "Notebook %s is already open"
                   (ein:$notebook-notebook-name notebook))
          (funcall callback0))
      (if (and pending-p noninteractive)
          (ein:log 'error "Notebook %s pending open!" path)
        (when (or (not pending-p)
                  (y-or-n-p (format "Notebook %s pending open!  Retry? " path)))
          (setf (gethash pending-key *ein:notebook--pending-query*) t)
          (add-function :before (var errback) pending-clear)
          (ein:content-query-contents url-or-port path
                                      (apply-partially #'ein:notebook-open--callback
                                                       notebook callback0)
                                      errback))))
    notebook))

(defun ein:notebook-open--callback (notebook callback0 content)
  (ein:log 'verbose "Opened notebook %s" (ein:$notebook-notebook-path notebook))
  (setf (ein:$notebook-api-version notebook) (ein:$content-notebook-api-version content)
        (ein:$notebook-notebook-name notebook) (ein:$content-name content))
  (ein:notebook-bind-events notebook (ein:events-new))
  (ein:notebook-set-kernelspec notebook (plist-get (ein:$content-raw-content content) :metadata))
  (ein:notebook--apply-session-kernel notebook)
  (ein:notebook-install-kernel notebook)
  (ein:notebook-from-json notebook (ein:$content-raw-content content)
                          (ein:$content-json content))
  (setf (ein:$notebook-last-modified notebook)
        (ein:$content-last-modified content))
  (if (not (with-current-buffer (ein:notebook-buffer notebook)
             (ein:get-notebook)))
      (error "ein:notebook-open--callback: notebook instantiation failed")
    ;; Start websocket only after worksheet is rendered
    ;; because ein:notification-bind-events only gets called after worksheet's
    ;; buffer local notification widget is instantiated
    (ein:kernel-retrieve-session (ein:$notebook-kernel notebook) nil
                                 (apply-partially (lambda (callback0* name* _kernel)
                                                    (funcall callback0*)
                                                    (ein:log 'info "Notebook %s is ready" name*))
                                                  callback0
                                                  (ein:$notebook-notebook-name notebook)))
    (setf (ein:$notebook-kernelinfo notebook)
          (ein:kernelinfo-new (ein:$notebook-kernel notebook)
                              (cons #'ein:notebook-buffer-list notebook)))
    (ein:notebook-put-opened-notebook notebook)
    (ein:notebook--check-nbformat (ein:$content-raw-content content))))

(defun ein:notebook-set-kernelspec (notebook content-metadata)
  (-when-let* ((ks-plist (plist-get content-metadata :kernelspec))
               (kernelspec (ein:get-kernelspec (ein:$notebook-url-or-port notebook)
                                               (plist-get ks-plist :name)
                                               (plist-get ks-plist :language))))
    (setf (ein:$notebook-kernelspec notebook) kernelspec)))


(defun ein:notebook--different-number (n1 n2)
  (and (numberp n1) (numberp n2) (not (= n1 n2))))

(defun ein:notebook--check-nbformat (data)
  "Warn user when nbformat is changed on server side.
See https://github.com/ipython/ipython/pull/1934 for the purpose
of minor mode."
  ;; See `Notebook.prototype.load_notebook_success'
  ;; at IPython/frontend/html/notebook/static/js/notebook.js
  (cl-destructuring-bind (&key nbformat orig_nbformat
                               nbformat_minor orig_nbformat_minor
                          &allow-other-keys)
      data
    (cond
     ((ein:notebook--different-number nbformat orig_nbformat)
      (ein:display-warning
       (format "Notebook major version updated (v%d -> v%d).
  To not update version, do not save this notebook."
               orig_nbformat nbformat)))
     ((ein:notebook--different-number nbformat_minor orig_nbformat_minor)
      (ein:display-warning
       (format "This notebook is version v%s.%s, but IPython
  server you are using only fully support up to v%s.%s.
  Some features may not be available."
               orig_nbformat orig_nbformat_minor
               nbformat nbformat_minor))))))

;;; Initialization.

(defun ein:notebook-bind-events (notebook events)
  "Bind events related to PAGER to the event handler EVENTS."
  (setf (ein:$notebook-events notebook) events)
  (ein:worksheet-class-bind-events events)
  ;; Bind events for sub components:
  (setf (ein:$notebook-pager notebook)
        (ein:pager-new
         (format ein:notebook-pager-buffer-name-template
                 (ein:$notebook-url-or-port notebook)
                 (ein:$notebook-notebook-name notebook))
         (ein:$notebook-events notebook))))

(defalias 'ein:notebook-reconnect-kernel 'ein:notebook-reconnect-session-command)

(define-obsolete-function-alias
  'ein:notebook-show-in-shared-output
  'ein:shared-output-show-code-cell-at-point "0.1.2")

;;; Kernel related things

(defun ein:list-available-kernels (url-or-port)
  (when-let* ((kernelspecs (ein:need-kernelspecs url-or-port)))
    (sort (cl-loop for (_key spec) on (ein:plist-exclude kernelspecs '(:default)) by 'cddr
                collecting (cons (ein:$kernelspec-name spec)
                                 (ein:$kernelspec-display-name spec)))
          (lambda (c1 c2) (string< (cdr c1) (cdr c2))))))

(defun ein:notebook-switch-kernel (notebook kernel-name)
  "Change the kernel for a running notebook. If not called from a
notebook buffer then the user will be prompted to select an opened notebook."
  (interactive
   (let* ((notebook (or (ein:get-notebook)
                        (ein:completing-read
                         "Select notebook: "
                         (ein:notebook-opened-buffer-names))))
          (kernel-name (ein:completing-read
                        "Select kernel: "
                        (cl-mapcar
                         #'car
                         (ein:list-available-kernels (ein:$notebook-url-or-port notebook))))))
     (list notebook kernel-name)))
  (let* ((kernelspec (ein:get-kernelspec
                      (ein:$notebook-url-or-port notebook) kernel-name))
         (windows (ignore-errors
                    (get-buffer-window-list (ein:notebook-buffer notebook) nil t))))
    (setf (ein:$notebook-kernelspec notebook) kernelspec)
    (puthash (cons (ein:$notebook-url-or-port notebook)
                   (ein:$notebook-notebook-path notebook))
             kernel-name ein:notebook--session-kernels)
    (setf (ein:$notebook-metadata notebook)
          (plist-put (ein:$notebook-metadata notebook)
                     :kernelspec (ein:notebook--kernelspec-metadata kernelspec)))
    (ein:notebook-save-notebook notebook #'ein:notebook-kill-kernel-then-close-command
                                (list notebook))
    (cl-loop repeat 10
          until (null (ein:$kernel-websocket (ein:$notebook-kernel notebook)))
          do (ein:accept-output-for 0.5)
          finally return (ein:notebook-open
                          (ein:$notebook-url-or-port notebook)
                          (ein:$notebook-notebook-path notebook) nil
                          (lambda (reopened _created)
                            (ein:notebook--show-in-windows reopened windows))
                          nil t))))

(defun ein:notebook--show-in-windows (notebook windows)
  "Show NOTEBOOK in the live ones of WINDOWS, which showed it before it
was reopened, selecting the first; else in the selected window."
  (let ((buffer (ein:notebook-buffer notebook))
        (live (seq-filter #'window-live-p windows)))
    (if (null live)
        (pop-to-buffer-same-window buffer)
      (dolist (w live) (set-window-buffer w buffer))
      (select-window (car live)))))

(defun ein:notebook-install-kernel (notebook)
  (let* ((base-url "/api/kernels")
         (kernelspec (ein:$notebook-kernelspec notebook))
         (kernel (ein:kernel-new
                  (ein:$notebook-url-or-port notebook)
                  (ein:$notebook-notebook-path notebook)
                  kernelspec
                  base-url
                  (ein:$notebook-events notebook)
                  (ein:$notebook-api-version notebook))))
    (setf (ein:$notebook-kernel notebook) kernel)))

(defun ein:notebook-reconnect-session-command ()
   "It seems convenient but undisciplined to blithely create a new
session if the original one no longer exists."
   (interactive)
   (ein:kernel-reconnect-session (ein:$notebook-kernel ein:%notebook%)))

(defun ein:notebook-restart-session-command ()
   "Delete session on server side.  Start new session."
  (interactive)
  (aif ein:%notebook%
      (if (y-or-n-p "Are you sure? ")
          (ein:kernel-restart-session (ein:$notebook-kernel it)))
    (message "Not in notebook buffer!")))

(define-obsolete-function-alias
  'ein:notebook-request-tool-tip-or-help-command
  'ein:pytools-request-tooltip-or-help "0.1.2")

(defun ein:notebook-kernel-interrupt-command ()
  "Interrupt the kernel.
This is equivalent to do ``C-c`` in the console program."
  (interactive)
  (ein:kernel-interrupt (ein:$notebook-kernel ein:%notebook%)))

(define-obsolete-function-alias
  'ein:notebook-eval-string
  'ein:shared-output-eval-string "0.1.2")

(defun ein:notebook-set-notebook-name (notebook name)
  "Check NAME and change the name of NOTEBOOK to it."
  (if (ein:notebook-test-notebook-name name)
      (setf (ein:$notebook-notebook-name notebook) name
            (ein:$notebook-notebook-id notebook) name)
    (ein:log 'error "%S is not a good notebook name." name)
    (error "%S is not a good notebook name." name)))

(defun ein:notebook-test-notebook-name (name)
  (and (stringp name)
       (> (length name) 0)
       (not (string-match "[\\/\\\\:]" name))))

(cl-defun ein:notebook--worksheet-new (notebook
                                       &optional (func #'ein:worksheet-new))
  (funcall func
	   (ein:$notebook-nbformat notebook)
           (apply-partially #'ein:$notebook-notebook-path notebook)
           (ein:$notebook-kernel notebook)
           (ein:$notebook-events notebook)))

(defvar ein:notebook--classic-warned nil
  "Non-nil once the classic view's deprecation warning was shown.")

(defun ein:notebook--worksheet-render (notebook ws)
  "Render WS of NOTEBOOK in the view chosen by `ein:notebook-view'."
  (if (eq ein:notebook-view 'cells)
      (ein:notebook--worksheet-render-cells notebook ws)
    (unless ein:notebook--classic-warned
      (setq ein:notebook--classic-warned t)
      (display-warning
       'ein
       "The classic notebook view is deprecated; set `ein:notebook-view' \
to `cells' for the cell-based view.  The classic view still works and \
is not removed."))
    (ein:notebook--worksheet-render-classic notebook ws)))

(defun ein:notebook--worksheet-render-cells (notebook ws)
  "Render WS of NOTEBOOK in the cells view (`ein:nbview').
Nothing executes: saved cells are only displayed."
  (require 'ein-nbview)
  (let ((buffer (generate-new-buffer (ein:worksheet--buffer-name ws))))
    (with-current-buffer buffer
      (let ((view (ein:nbview-open notebook ws buffer)))
        (setf (ein:$notebook-view notebook) view)
        (setq ein:%notebook% notebook)
        (ein:worksheet-bind-events ws)
        (ein:worksheet-set-kernel ws)
        (ein:notebook--notification-setup notebook)
        (ein:nbview-toolbar-setup notebook view)
        (set-buffer-modified-p nil)
        (setq buffer-undo-list nil)))))

(defun ein:notebook--worksheet-render-classic (notebook ws)
  "Render WS of NOTEBOOK in the classic ewoc view."
  (ein:worksheet-render ws)
  (with-current-buffer (ein:worksheet-buffer ws)
    (poly-ein-mode)
    (ein:notebook-mode)
    (ein:notebook--notification-setup notebook)
    (setq ein:%notebook% notebook)
    (poly-ein-fontify-buffer (current-buffer))))

(defun ein:notebook--view (notebook)
  "Return NOTEBOOK's `ein:view', making a classic one when none is set."
  (or (ein:$notebook-view notebook)
      (setf (ein:$notebook-view notebook)
            (make-instance 'ein:classic-view
                           :worksheet (car (ein:$notebook-worksheets notebook))))))

(defun ein:notebook--notification-setup (notebook)
  (ein:notification-setup
   (current-buffer)
   (ein:$notebook-events notebook)
   :get-list
   (lambda () (ein:$notebook-worksheets ein:%notebook%))
   :get-current
   (lambda () ein:%worksheet%)))

(defun ein:notebook--parse (string)
  "Parse notebook JSON STRING as `ein:json-read-faithful' would.
Signal `user-error' when STRING is not JSON."
  (condition-case err
      (json-parse-string string :object-type 'plist :array-type 'array
                         :null-object :null :false-object json-false)
    (json-error
     (user-error "Notebook is not valid JSON (%s)" (error-message-string err)))))

(defun ein:notebook--validate (data)
  "Signal `user-error' unless DATA is an nbformat 4 notebook EIN can open."
  (unless (and (consp data) (keywordp (car data)))
    (user-error "Notebook is not valid JSON (expected an object)"))
  (let ((nbformat (plist-get data :nbformat))
        (cells (plist-get data :cells))
        (minor (plist-get data :nbformat_minor)))
    (cond ((eql nbformat 3)
           (user-error "Unsupported nbformat 3 (Jupyter Server normally upgrades it)"))
          ((not (eql nbformat 4))
           (user-error "Unsupported nbformat %s" nbformat))
          ;; Read by `ein:json-read-faithful', a JSON array is a vector
          ;; and an empty object is nil.
          ((not (vectorp cells))
           (user-error "Notebook has no cell list"))
          ((not (or (null minor) (natnump minor)))
           (user-error "Notebook has an invalid nbformat_minor %S" minor)))))

(defun ein:notebook--repair-duplicate-ids (cells)
  "Return CELLS, a list of cell plists, with each `:id' made unique.
A repeated id gets the first free suffix -1, -2, ...; the repaired
cell is a modified copy and a warning is logged."
  (let ((seen (make-hash-table :test #'equal))
        (taken (make-hash-table :test #'equal)))
    (dolist (cell cells)
      (let ((id (plist-get cell :id)))
        (when (stringp id) (puthash id t seen))))
    (mapcar
     (lambda (cell)
       (let ((id (plist-get cell :id)))
         (cond ((not (stringp id)) cell)
               ((not (gethash id taken)) (puthash id t taken) cell)
               (t (let* ((n 1) (new (format "%s-%d" id n)))
                    (while (or (gethash new taken) (gethash new seen))
                      (setq n (1+ n) new (format "%s-%d" id n)))
                    (puthash new t taken)
                    (ein:log 'warn "Duplicate cell id %s renamed to %s" id new)
                    (plist-put (copy-sequence cell) :id new))))))
     cells)))

(defun ein:notebook-from-json (notebook data &optional raw)
  "Fill NOTEBOOK from DATA, a parsed nbformat 4 notebook with null as nil.
RAW is the same notebook as read by `ein:json-read-faithful'; it is
kept so that saving reproduces keys EIN does not own (default DATA).
Signal `user-error' before creating any buffer when DATA is invalid."
  (ein:notebook--validate data)
  (setq raw (or raw data))
  (cl-destructuring-bind (&key metadata nbformat nbformat_minor
                          &allow-other-keys)
      data
    (setf (ein:$notebook-metadata notebook) metadata)
    (setf (ein:$notebook-nbformat notebook) nbformat)
    (setf (ein:$notebook-nbformat-minor notebook) nbformat_minor)
    (setf (ein:$notebook-raw notebook) raw))
  (setf (ein:$notebook-worksheets notebook)
        (ein:read-nbformat4-worksheets notebook data raw))
  (awhen (ein:$notebook-worksheets notebook)
    (ein:notebook--worksheet-render notebook (cl-first it)))
  notebook)

(defun ein:read-nbformat3-worksheets (notebook data)
  (mapcar (lambda (ws-data)
                    (ein:worksheet-from-json
                     (ein:notebook--worksheet-new notebook)
                     ws-data))
          (or (plist-get data :worksheets)
              (list nil))))

;; nbformat4 gets rid of the concept of worksheets. That means, for the moment,
;; ein will no longer support worksheets. There may be a path forward for
;; reimplementing this feature, however.  The nbformat 4 json definition says
;; that cells are allowed to have tags. Clever use of this feature may lead to
;; good things.

(defun ein:read-nbformat4-worksheets (notebook data &optional raw)
  "Convert a notebook in nbformat4 to a list of worksheet-like
  objects suitable for processing in ein:notebook-from-json.
RAW is DATA as read faithfully; its cells become the cells' `raw'."
  (let* ((raw-cells (ein:notebook--repair-duplicate-ids
                     (append (plist-get (or raw data) :cells) nil)))
         (ws-cells (mapcar (lambda (raw-cell)
                             (ein:cell-from-json (ein:json-nilify raw-cell)
                                                 :raw raw-cell))
                           raw-cells))
         (worksheet (ein:notebook--worksheet-new notebook)))
    (setf (oref worksheet saved-cells) ws-cells)
    ;(mapcar (lambda (data) (message "test %s" (slot-value data 'metadata))) ws-cells)
    (list worksheet)))

(defun ein:notebook--kernelspec-changed (notebook)
  "Non-nil when NOTEBOOK's kernelspec metadata differs from the one read.
The kernel-switch command is the only writer of that key (G4)."
  (not (equal (plist-get (ein:$notebook-metadata notebook) :kernelspec)
              (plist-get (ein:json-nilify
                          (plist-get (ein:$notebook-raw notebook) :metadata))
                         :kernelspec))))

(defun ein:notebook-to-json (notebook)
  "Return NOTEBOOK as a json-ready alist (see `ein:json-encode-notebook').
Keys EIN does not own are copied from the notebook as read, so a save
without edits reproduces it (contracts/notebook-roundtrip.md G2-G9)."
  (let* ((raw (ein:$notebook-raw notebook))
         (minor (ein:$notebook-nbformat-minor notebook))
         (rest (cl-loop for (k v) on raw by #'cddr
                        unless (memq k '(:nbformat :nbformat_minor :metadata :cells))
                        collect (cons (intern (substring (symbol-name k) 1)) v))))
    `((nbformat . 4)
      ;; Cells always carry ids, which nbformat < 4.5 forbids: G9(b).
      (nbformat_minor . ,(if (and (natnump minor) (>= minor 5)) minor 5))
      ,@(ein:write-nbformat4-worksheets notebook)
      ,@rest)))


(defun ein:write-nbformat3-worksheets (notebook)
  (let ((worksheets (mapcar #'ein:worksheet-to-json
                            (ein:$notebook-worksheets notebook))))
    `((worksheets . ,(apply #'vector worksheets))
      (metadata . ,(ein:$notebook-metadata notebook))
      )))

(defun ein:write-nbformat4-worksheets (notebook)
  (let ((all-cells (cl-loop for ws in (ein:$notebook-worksheets notebook)
                         for i from 0
                         append (ein:worksheet-to-nb4-json ws i)))
        (raw-cells (plist-get (ein:$notebook-raw notebook) :cells)))
    ;; A notebook read with no cells is shown with one blank code cell
    ;; to type in; while it stays blank it is not part of the notebook.
    (when (and raw-cells (zerop (length raw-cells))
               (= 1 (length all-cells))
               (let ((cell (car all-cells)))
                 (and (equal (alist-get 'cell_type cell) "code")
                      (equal (alist-get 'source cell) "")
                      (zerop (length (alist-get 'outputs cell))))))
      (setq all-cells nil))
    `((metadata . ,(ein:json-prefer-raw
                    (ein:$notebook-metadata notebook)
                    (plist-get (ein:$notebook-raw notebook) :metadata)))
      (cells . ,(apply #'vector all-cells)))))

(defun ein:notebook-save-notebook (notebook &optional callback cbargs errback)
  (condition-case err
      (with-current-buffer (ein:notebook-buffer notebook)
        (cl-letf (((symbol-function 'delete-trailing-whitespace) #'ignore))
          (run-hooks 'before-save-hook)))
    (error (ein:log 'warn "ein:notebook-save-notebook: Saving despite '%s'."
                    (error-message-string err))))
  ;; Build (and encode) the body before any request: a notebook that
  ;; cannot be encoded signals here and stays modified (T069).
  (let ((content (ein:content-from-notebook notebook)))
    (ein:content-to-json content)
    (ein:notebook--check-conflict
     notebook
     (lambda ()
       (ein:events-trigger (ein:$notebook-events notebook)
                           'notebook_saving.Notebook)
       (ein:content-save content
                         (lambda (&rest args)
                           (setf (ein:$notebook-last-modified notebook)
                                 (ein:$content-last-modified content))
                           (apply #'ein:notebook-save-notebook-success args))
                         (list notebook callback cbargs)
                         #'ein:notebook-save-notebook-error
                         (list notebook errback))))))

(defun ein:notebook--confirm-overwrite (notebook)
  "Ask what to do about NOTEBOOK having changed on the server.
Return `overwrite', `reload' or `cancel'."
  (pcase (car (read-multiple-choice
               (format "%s changed on the server since it was opened or saved"
                       (ein:$notebook-notebook-name notebook))
               '((?o "overwrite" "Replace the server copy with this buffer")
                 (?r "reload" "Discard local edits and reopen from the server")
                 (?c "cancel" "Do not save; keep the buffer modified"))))
    (?o 'overwrite)
    (?r 'reload)
    (_ 'cancel)))

(defun ein:notebook--reload (notebook)
  "Reopen NOTEBOOK from the server after confirming loss of local edits."
  (when (yes-or-no-p "Discard local edits and reopen from the server? ")
    (let ((url-or-port (ein:$notebook-url-or-port notebook))
          (path (ein:$notebook-notebook-path notebook)))
      (dolist (ws (ein:$notebook-worksheets notebook))
        (ein:worksheet-set-modified-p ws nil))
      (setf (ein:$notebook-dirty notebook) nil)
      (ein:notebook-close notebook
                          (lambda () (ein:notebook-open url-or-port path))))))

(defun ein:notebook--check-conflict (notebook proceed)
  "Call PROCEED unless NOTEBOOK changed on the server and the user declines.
Compares the server's `last_modified' with the value recorded at open
or at the last save (T070).  Without a recorded value, just PROCEED."
  (let ((recorded (ein:$notebook-last-modified notebook)))
    (if (null recorded)
        (funcall proceed)
      (ein:content-query-last-modified
       (ein:$notebook-url-or-port notebook)
       (ein:$notebook-notebook-path notebook)
       (lambda (current)
         (if (or (null current) (equal current recorded))
             (funcall proceed)
           (pcase (ein:notebook--confirm-overwrite notebook)
             ('overwrite (funcall proceed))
             ('reload (ein:notebook--reload notebook))
             (_ (message "Save cancelled; notebook still modified")))))))))

(defun ein:notebook-save-notebook-command ()
  "Save the notebook."
  (interactive)
  (ein:notebook-save-notebook ein:%notebook%))

(defun ein:notebook-save-notebook-success (notebook &optional callback cbargs)
  (ein:log 'verbose "Notebook is saved.")
  (setf (ein:$notebook-dirty notebook) nil)
  (mapc (lambda (ws)
          (ein:worksheet-save-cells ws) ; [#]_
          (ein:worksheet-set-modified-p ws nil))
        (ein:$notebook-worksheets notebook))
  (ein:events-trigger (ein:$notebook-events notebook)
                      'notebook_saved.Notebook)
  (when callback
    (apply callback cbargs)))

;; .. [#] Consider the following case.
;;    (1) Open worksheet WS0 and other worksheets.
;;    (2) Edit worksheet WS0 then save the notebook.
;;    (3) Edit worksheet WS0.
;;    (4) Kill WS0 buffer by discarding the edit.
;;    (5) Save the notebook.
;;    This should save the latest WS0.  To do so, WS0 at the point (2)
;;    must be cached in the worksheet slot `:saved-cells'.

(cl-defun ein:notebook-save-notebook-error (notebook &optional errback
                                            &key reason symbol-status
                                            &allow-other-keys)
  "Report a failed save of NOTEBOOK; it stays modified.  Then call ERRBACK."
  (if (eq symbol-status 'user-cancel)
      (ein:log 'info "Cancelled save.")
    (let ((msg (format "Save failed (%s); notebook still modified — retry with C-x C-s"
                       (or reason "unknown error"))))
      (ein:log 'warn "%s" msg)
      (ein:events-trigger (ein:$notebook-events notebook)
                          'notebook_save_failed.Notebook)
      (message "%s" msg)))
  (when errback
    (funcall errback)))

(defun ein:notebook-rename-command (path)
  "Rename current notebook and save it immediately.
NAME is any non-empty string that does not contain '/' or '\\'."
  (interactive
   (list (read-string "Rename to: "
                      (ein:$notebook-notebook-path ein:%notebook%))))
  (unless (and (string-match "\\.ipynb" path) (= (match-end 0) (length path)))
    (setq path (format "%s.ipynb" path)))
  (let* ((notebook (ein:notebook--get-nb-or-error))
         (content (ein:content-from-notebook notebook)))
    (ein:log 'verbose "Renaming notebook %s to '%s'" (ein:notebook-url notebook) path)
    (ein:content-rename content path #'ein:notebook-rename-success
                        (list notebook content))))

(defun ein:notebook-save-to-command (path)
  "Make a copy of the notebook and save it to a new path specified by NAME.
NAME is any non-empty string that does not contain '/' or '\\'.
"
  (interactive
   (list (read-string "Save copy to: " (ein:$notebook-notebook-path ein:%notebook%))))
  (unless (and (string-match ".ipynb" path) (= (match-end 0) (length path)))
    (setq path (format "%s.ipynb" path)))
  (let* ((content (ein:content-from-notebook ein:%notebook%))
         (name (substring path (or (cl-position ?/ path :from-end t) 0))))
    (setf (ein:$content-path content) path
          (ein:$content-name content) name)
    (ein:content-save content #'ein:notebook-open
                      (list (ein:$notebook-url-or-port ein:%notebook%)
                            path))))

(cl-defun ein:notebook-rename-success (notebook content)
  (ein:notebook-remove-opened-notebook notebook)
  (ein:notebook-set-notebook-name notebook (ein:$content-name content))
  (setf (ein:$notebook-notebook-path notebook) (ein:$content-path content))
  (ein:notebook-put-opened-notebook notebook)
  (mapc #'ein:worksheet-set-buffer-name
        (append (ein:$notebook-worksheets notebook)
                (ein:$notebook-scratchsheets notebook)))
  (when-let* ((kernel (ein:$notebook-kernel notebook)))
    (ein:session-rename (ein:$kernel-url-or-port kernel)
                        (ein:$kernel-session-id kernel)
                        (ein:$content-path content))
    (setf (ein:$kernel-path kernel) (ein:$content-path content)))
  (ein:log 'info "Notebook renamed to %s." (ein:$content-name content)))

(defmacro ein:notebook-avoid-recursion (&rest body)
  `(let ((kill-buffer-query-functions
          (cl-remove-if (lambda (x) (eq 'ein:notebook-kill-buffer-query x))
                        kill-buffer-query-functions)))
     ,@body))

(defun ein:notebook-kill-buffers (notebook)
  "Callback for `ein:notebook-close'"
  (let ((buffers (ein:notebook-buffer-list notebook)))
    (mapc (lambda (b)
            (with-current-buffer b
              (awhen ein:%worksheet%
                (ein:notebook-close-worksheet ein:%notebook% it))
              (awhen ein:%notebook%
                (ein:notebook-tidy-opened-notebooks it))))
          buffers)
    (ein:notebook-avoid-recursion
     (mapc (lambda (b) (ignore-errors (kill-buffer b))) buffers))))

(defun ein:notebook-kill-buffer-query ()
  (if-let* ((notebook (ein:get-notebook))
           (ws ein:%worksheet%))
      (prog1 nil
        (cond ((ein:scratchsheet-p ws)
               (ein:notebook-close-worksheet notebook ws)
               (awhen (ein:worksheet-buffer ws)
                 (with-current-buffer it
                   (ein:notebook-avoid-recursion
                    (mapc (lambda (b) (ignore-errors (kill-buffer b)))
                          (if (bound-and-true-p pm/polymode)
                              (eieio-oref pm/polymode '-buffers)
                            (list (current-buffer))))))))
              (t
               (cl-assert (ein:worksheet-p ws))
               (ein:notebook-close notebook))))
    t))

(defun ein:notebook-ask-save (notebook &optional callback0)
  "Return t if proceeding with kill-buffer."
  (unless callback0
    (setq callback0 #'ignore))
  (if (and (ein:notebook-modified-p notebook)
           (not (ob-ein-anonymous-p (ein:$notebook-notebook-path notebook))))
      (if (y-or-n-p (format "Save %s?" (ein:$notebook-notebook-name notebook)))
          (let ((ein:force-sync t))
            (let ((success-positive 0))
              (add-function :before (var callback0)
                            (lambda (&rest _args) (setq success-positive 1)))
              (ein:notebook-save-notebook notebook callback0 nil
                                          (lambda (&rest _args) (setq success-positive -1)))
              (> success-positive 0)))
        (when (ein:worksheet-p ein:%worksheet%)
          (ein:worksheet-dont-save-cells ein:%worksheet%)) ;; TODO de-obfuscate
        (funcall callback0)
        t)
    (funcall callback0)
    t))

(defun ein:notebook-close (notebook &optional callback &rest cbargs)
  (interactive (list (ein:notebook--get-nb-or-error)))
  (let* ((notebook (or notebook (ein:notebook--get-nb-or-error)))
         (callback0 (apply-partially #'ein:notebook-kill-buffers notebook)))
    (when callback
      (add-function :after (var callback0)
                    (apply #'apply-partially callback cbargs)))
    (ein:notebook-ask-save notebook callback0)))

(defun ein:notebook-kill-kernel-then-close-command (notebook &optional callback1)
  "Kill kernel and then kill notebook buffer.
To close notebook without killing kernel, just close the buffer
as usual."
  (interactive (list (ein:notebook--get-nb-or-error) nil))
  (unless callback1 (setq callback1 #'ignore))
  (let* ((kernel (ein:$notebook-kernel notebook))
         (callback (apply-partially
                    (lambda (notebook* cb* kernel*)
                      (ein:notebook-close notebook*)
                      (funcall cb* kernel*))
                    notebook callback1)))
    (if (ein:kernel-live-p kernel)
        (ein:message-whir "Ending session" (var callback)
                          (ein:kernel-delete-session callback :kernel kernel))
      (funcall callback nil))))

(defmacro ein:notebook--worksheet-render-new (notebook type)
  "Create new worksheet of TYPE in NOTEBOOK."
  (let ((func (intern (format "ein:%s-new" type)))
        (slot (list (intern (format "ein:$notebook-%ss" type)) notebook)))
    `(let ((ws (ein:notebook--worksheet-new ,notebook #',func)))
       (setf ,slot (append ,slot (list ws)))
       (ein:notebook--worksheet-render ,notebook ws)
       ws)))

(defun ein:notebook-scratchsheet-render-new (notebook)
  "Create new scratchsheet in NOTEBOOK."
  (ein:notebook--worksheet-render-new notebook scratchsheet))

(defun ein:notebook-scratchsheet-open (notebook &optional new popup)
  "Open \"scratch sheet\".
Open a new one when prefix argument is given.
Scratch sheet is almost identical to worksheet.  However, EIN
will not save the buffer.  Use this buffer like of normal IPython
console.  Note that you can always copy cells into the normal
worksheet to save result."
  (interactive (list (ein:notebook--get-nb-or-error)
                     current-prefix-arg
                     t))
  (let ((ss (or (unless new
                  (car (ein:$notebook-scratchsheets notebook)))
                (ein:notebook-scratchsheet-render-new notebook))))
    (when popup
      (pop-to-buffer (ein:worksheet-buffer ss)))
    ss))

(defvar ein:notebook--opened-map (make-hash-table :test 'equal)
  "A map: (URL-OR-PORT NOTEBOOK-ID) => notebook instance.")

(defun ein:notebook-get-opened-notebook (url-or-port path)
  (gethash (list url-or-port path) ein:notebook--opened-map))

(defun ein:notebook--live-opened-notebook (url-or-port path)
  "The opened notebook of URL-OR-PORT and PATH whose buffer is live.
A notebook whose buffer was killed without going through
`ein:notebook-close' is forgotten, so that opening it again reads it
from the server instead of reusing a notebook with no buffer."
  (when-let* ((notebook (ein:notebook-get-opened-notebook url-or-port path)))
    (if (buffer-live-p (ein:notebook-buffer notebook))
        notebook
      (ein:notebook-remove-opened-notebook notebook)
      nil)))

(defun ein:notebook-put-opened-notebook (notebook)
  (puthash (list (ein:$notebook-url-or-port notebook)
                 (ein:$notebook-notebook-path notebook))
           notebook
           ein:notebook--opened-map))

(defun ein:notebook-tidy-opened-notebooks (notebook)
  "Remove NOTEBOOK from ein:notebook--opened-map if it's not ein:notebook-live-p"
  (when (ein:notebook-live-p notebook)
    (ein:notebook-remove-opened-notebook notebook)))

(defun ein:notebook-remove-opened-notebook (notebook)
  (remhash (list (ein:$notebook-url-or-port notebook)
                 (ein:$notebook-notebook-path notebook))
           ein:notebook--opened-map))

(defun ein:notebook-opened-notebooks (&optional predicate)
  "Return list of opened notebook instances.
If PREDICATE is given, notebooks are filtered by PREDICATE.
PREDICATE is called with each notebook and notebook is included
in the returned list only when PREDICATE returns non-nil value."
  (let ((notebooks (hash-table-values ein:notebook--opened-map)))
    (if predicate
        (seq-filter predicate notebooks)
      notebooks)))

(defun ein:notebook-opened-buffers (&optional predicate)
  "Return list of opened notebook buffers."
  (mapcar #'ein:notebook-buffer (ein:notebook-opened-notebooks predicate)))

(defun ein:notebook-opened-buffer-names (&optional predicate)
  "Return list of opened notebook buffer names.
If PREDICATE is given, the list is filtered by PREDICATE.
PREDICATE is called with the buffer name for each opened notebook."
  (let ((notebooks (mapcar #'buffer-name (ein:notebook-opened-buffers))))
    (if predicate
        (seq-filter predicate notebooks)
      notebooks)))

(defun ein:get-url-or-port--notebook ()
  (when ein:%notebook% (ein:$notebook-url-or-port ein:%notebook%)))

(defun ein:get-kernel--notebook ()
  (when (ein:$notebook-p ein:%notebook%)
    (ein:$notebook-kernel ein:%notebook%)))

(defun ein:notebook-live-p (notebook)
  "Return non-`nil' if NOTEBOOK has live buffer."
  (buffer-live-p (ein:notebook-buffer notebook)))

(defun ein:notebook-modified-p (&optional notebook)
  "Return non-nil if NOTEBOOK is modified.
If NOTEBOOK is not given or nil then consider the notebook
associated with current buffer (if any)."
  (unless notebook (setq notebook ein:%notebook%))
  (and (ein:$notebook-p notebook)
       (ein:notebook-live-p notebook)
       (or (ein:$notebook-dirty notebook)
           (cl-loop for ws in (ein:$notebook-worksheets notebook)
                 when (ein:worksheet-modified-p ws)
                 return t))))

(defvar ein:notebook-mode-map (make-sparse-keymap))

(defun ein:notebook--call-command (defn)
  "Call command DEFN interactively, in the polymode base buffer if any."
  (if (bound-and-true-p poly-ein-mode)
      (poly-ein-call-in-base (lambda () (call-interactively defn)))
    (call-interactively defn)))

(defmacro ein:notebook--define-key (keymap key defn)
  "Ideally we could override just the keymap binding with a
(string . wrapped) cons pair (as opposed to messing with the DEFN
itself), but then describe-minor-mode unhelpfully shows ?? for
the keymap commands.

Tried add-function: the &rest from :around is an emacs-25
compilation issue."
  (let ((km (intern (concat (symbol-name defn) "-km")))
	(docstring (and (functionp defn) (ein:get-docstring defn))))
    `(if ,docstring
         (progn
           (fset (quote ,km) (lambda () ,docstring (interactive)
                               (condition-case-unless-debug err
                                   (ein:notebook--call-command (function ,defn))
                                 (cl-no-method (message "%s: no applicable method" (quote ,km)))
                                 (error (message "%s: %s" (quote ,km) (error-message-string err))))))
           (define-key ,keymap ,key (quote ,km)))
       (define-key ,keymap ,key (quote ,defn)))))

(let ((map ein:notebook-mode-map))
  (ein:notebook--define-key map "\C-c\C-c" ein:worksheet-execute-cell)
  (ein:notebook--define-key map (kbd "M-RET") ein:worksheet-execute-cell-and-goto-next)
  (ein:notebook--define-key map (kbd "<M-S-return>")
    ein:worksheet-execute-cell-and-insert-below)
  (ein:notebook--define-key map "\C-c\C-e" ein:worksheet-toggle-output)
  (ein:notebook--define-key map "\C-c\C-v" ein:worksheet-set-output-visibility-all)
  (ein:notebook--define-key map "\C-c\C-l" ein:worksheet-clear-output)
  (ein:notebook--define-key map (kbd "C-c C-S-l") ein:worksheet-clear-all-output)
  (ein:notebook--define-key map (kbd "C-c C-;") ein:shared-output-show-code-cell-at-point)
  (ein:notebook--define-key map "\C-c\C-k" ein:worksheet-kill-cell)
  (ein:notebook--define-key map "\C-c\M-w" ein:worksheet-copy-cell)
  (ein:notebook--define-key map "\C-c\C-w" ein:worksheet-copy-cell)
  (ein:notebook--define-key map "\C-c\C-y" ein:worksheet-yank-cell)
  (ein:notebook--define-key map "\C-c\C-a" ein:worksheet-insert-cell-above)
  (ein:notebook--define-key map "\C-c\C-b" ein:worksheet-insert-cell-below)
  (ein:notebook--define-key map "\C-c\C-t" ein:worksheet-toggle-cell-type)
  (ein:notebook--define-key map "\C-c\C-u" ein:worksheet-change-cell-type)
  (ein:notebook--define-key map "\C-c\C-s" ein:worksheet-split-cell-at-point)
  (ein:notebook--define-key map "\C-c\C-m" ein:worksheet-merge-cell)
  (ein:notebook--define-key map "\C-c\C-n" ein:worksheet-goto-next-input)
  (ein:notebook--define-key map "\C-c\C-p" ein:worksheet-goto-prev-input)
  (ein:notebook--define-key map (kbd "C-<up>") ein:worksheet-goto-prev-input)
  (ein:notebook--define-key map (kbd "C-<down>") ein:worksheet-goto-next-input)
  (ein:notebook--define-key map (kbd "C-c <up>") ein:worksheet-move-cell-up)
  (ein:notebook--define-key map (kbd "C-c <down>") ein:worksheet-move-cell-down)
  (ein:notebook--define-key map (kbd "M-<up>") ein:worksheet-not-move-cell-up)
  (ein:notebook--define-key map (kbd "M-<down>") ein:worksheet-not-move-cell-down)
  (ein:notebook--define-key map (kbd "C-c C-$") ein:tb-show)
  (ein:notebook--define-key map "\C-c\C-x" nil)
  (ein:notebook--define-key map "\C-c\C-x\C-r" ein:notebook-restart-session-command)
  (ein:notebook--define-key map "\C-c\C-r" ein:notebook-reconnect-session-command)
  (ein:notebook--define-key map "\C-c\C-z" ein:notebook-kernel-interrupt-command)
  (ein:notebook--define-key map "\C-c\C-q" ein:notebook-kill-kernel-then-close-command)
  (ein:notebook--define-key map (kbd "C-c C-#") ein:notebook-close)
  (ein:notebook--define-key map "\C-c\C-f" ein:file-open)
  (ein:notebook--define-key map "\C-c\C-o" ein:notebook-open)
  (ein:notebook--define-key map "\C-x\C-s" ein:notebook-save-notebook-command)
  (ein:notebook--define-key map "\C-x\C-w" ein:notebook-rename-command)
  (define-key map "\M-."          'ein:pytools-jump-to-source-command)
  (define-key map "\M-,"          'ein:pytools-jump-back-command)
  (ein:notebook--define-key map (kbd "C-c C-/") ein:notebook-scratchsheet-open)
  (easy-menu-define ein:notebook-menu map "EIN Notebook Mode Menu"
    `("EIN Notebook"
      ("File"
       ,@(ein:generate-menu
          '(("Save notebook" ein:notebook-save-notebook-command)
            ("Copy and rename notebook" ein:notebook-save-to-command)
            ("Rename notebook" ein:notebook-rename-command)
            ("Close notebook" ein:notebook-close)
            ("Kill kernel then close notebook"
             ein:notebook-kill-kernel-then-close-command))))
      ("Edit"
       ,@(ein:generate-menu
          '(("Kill cell" ein:worksheet-kill-cell)
            ("Copy cell" ein:worksheet-copy-cell)
            ("Yank cell" ein:worksheet-yank-cell)
            ("Insert cell above" ein:worksheet-insert-cell-above)
            ("Insert cell below" ein:worksheet-insert-cell-below)
            ("Toggle cell type" ein:worksheet-toggle-cell-type)
            ("Change cell type" ein:worksheet-change-cell-type)
            ("Split cell at point" ein:worksheet-split-cell-at-point)
            ("Merge cell" ein:worksheet-merge-cell)
            ("Go to next cell" ein:worksheet-goto-next-input)
            ("Go to previous cell" ein:worksheet-goto-prev-input)
            ("Move cell up" ein:worksheet-move-cell-up)
            ("Move cell down" ein:worksheet-move-cell-down)
            ("Dedent text in CELL" ein:worksheet-dedent-cell-text)
            )))
      ("Cell/Code"
       ,@(ein:generate-menu
          '(("Execute cell" ein:worksheet-execute-cell
             :active (ein:worksheet-at-codecell-p))
            ("Execute cell and go to next"
             ein:worksheet-execute-cell-and-goto-next
             :active (ein:worksheet-at-codecell-p))
            ("Execute cell and insert below"
             ein:worksheet-execute-cell-and-insert-below
             :active (ein:worksheet-at-codecell-p))
            ("Execute all cells"
             ein:worksheet-execute-all-cells)
	    ("Execute all cells above"
             ein:worksheet-execute-all-cells-above)
	    ("Execute all cells below"
             ein:worksheet-execute-all-cells-below)
            ))
       "---"
       ,@(ein:generate-menu
          '(("Toggle output visibility" ein:worksheet-toggle-output
             :active (ein:worksheet-at-codecell-p))
            ("Show all output"
             ein:worksheet-set-output-visibility-all)
            ("Discard output" ein:worksheet-clear-output
             :active (ein:worksheet-at-codecell-p))
            ("Discard all output" ein:worksheet-clear-all-output)
            ("Show full output" ein:shared-output-show-code-cell-at-point
             :active (ein:worksheet-at-codecell-p))
            ("Traceback viewer" ein:tb-show)
            ))
       "---"
       ,@(ein:generate-menu
          '(("Jump to definition" ein:pytools-jump-to-source-command)
            ("Go back to the previous jump point"
             ein:pytools-jump-back-command))))
      ("Kernel"
       ,@(ein:generate-menu
          '(("Restart session" ein:notebook-restart-session-command)
            ("Reconnect session" ein:notebook-reconnect-session-command)
            ("Switch kernel" ein:notebook-switch-kernel)
            ("Interrupt kernel" ein:notebook-kernel-interrupt-command))))
      ;; Misc:
      ,@(ein:generate-menu
         '(("Open scratch sheet" ein:notebook-scratchsheet-open)))))
  map)

(define-minor-mode ein:notebook-mode
  "A mode for jupyter notebooks.

\\{ein:notebook-mode-map}
"
  :init-value nil
  :lighter " Notebook"
  :keymap ein:notebook-mode-map
  :group 'ein

  ;; BODY contains code to execute each time the mode is enabled or disabled.
  ;; It is executed after toggling the mode, and before running MODE-hook.

  )

(defun ein:notebook-fetch-data (notebook callback &optional cbargs)
  "Fetch data in body tag of NOTEBOOK html page.
CALLBACK is called with a plist with data in the body tag as
the first argument and CBARGS as the rest of arguments."
  (let ((url-or-port (ein:$notebook-url-or-port notebook))
        (notebook-id (ein:$notebook-notebook-id notebook)))
    (ein:query-singleton-ajax
     (ein:url url-or-port notebook-id)
     :parser
     (lambda ()
       (list
        :project
        (ein:html-get-data-in-body-tag "data-project")
        :base-project-url
        (ein:html-get-data-in-body-tag "data-base-project-url")
        :base-kernel-url
        (ein:html-get-data-in-body-tag "data-base-kernel-url")
        :read-only
        (ein:html-get-data-in-body-tag "data-read-only")
        :notebook-id
        (ein:html-get-data-in-body-tag "data-notebook-id")))
     :success
     (apply-partially (cl-function
                       (lambda (callback cbargs &key data &allow-other-keys)
                         (apply callback data cbargs)))
                      callback cbargs))))

(defun ein:notebook-close-notebooks (&optional predicate blithely)
  "Used in `ein:jupyter-server-stop' and `kill-emacs-hook'."
  (aif (ein:notebook-opened-notebooks predicate)
      (if (and (cl-notevery #'identity (mapcar #'ein:notebook-close it))
               (not blithely))
          (y-or-n-p "Some notebooks could not be saved.  Exit anyway?")
        t)
    t))

(defsubst ein:notebook-forbid-narrow-to-region (&rest _args)
  "Narrowing causes severe problems for EIN.
Stefan Monnier, the author of `called-interactively-p' warns
against its use.  It should err on the side of a false negative,
that is, it might return nil when the call was really
interactive.  In that case, we are no worse off than when we
didn't have this safeguard at all (modulo the increased latency
of the `add-function').  Far worse would be if noninteractive
notebook code attempted to narrow-to-region, and
`called-interactively-p' mistakenly returned t."
  (and (ein:eval-if-bound 'ein:notebook-mode)
       (called-interactively-p 'any)
       (message "`narrow-to-region' disabled under EIN")))

;; I tried to make this buffer-local, but when rewriting ein:notebook-avoid-recursion,
;; (with-current-buffer b
;;   (let (kill-buffer-query-functions)
;;     (kill-buffer)))
;; is problematic.
(add-hook 'kill-buffer-query-functions 'ein:notebook-kill-buffer-query)
(add-hook 'kill-emacs-hook (lambda () (ignore-errors (ein:jupyter-server-stop))))
(remove-function (symbol-function 'narrow-to-region)
                  #'ein:notebook-forbid-narrow-to-region)
(add-function
 :before-until (symbol-function 'narrow-to-region)
 #'ein:notebook-forbid-narrow-to-region)

(ein:python-send--init)

(provide 'ein-notebook)

;;; ein-notebook.el ends here
