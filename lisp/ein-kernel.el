;;; ein-kernel.el --- Communicate with IPython notebook server    -*- lexical-binding:t -*-

;; Copyright (C) 2012- Takafumi Arakaki

;; Author: Takafumi Arakaki <aka.tkf at gmail.com>

;; This file is NOT part of GNU Emacs.

;; ein-kernel.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-kernel.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-kernel.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; `ein:kernel' is the proxy class of notebook server state.
;; It agglomerates both the "kernel" and "session" objects of server described here
;; https://github.com/jupyter/jupyter/wiki/Jupyter-Notebook-Server-API
;; It may have been better to keep them separate to allow parallel reasoning with
;; the notebook server, but that time is past.

;;; Code:

(require 'ansi-color)

(require 'ein-core)
(require 'ein-classes)
(require 'ein-log)
(require 'ein-websocket)
(require 'ein-events)
(require 'ein-query)
(require 'ein-ipdb)

(declare-function ein:notebook-get-opened-notebook "ein-notebook")
(declare-function ein:notebooklist-get-buffer "ein-notebooklist")
(declare-function ein:notebooklist-reload "ein-notebooklist")

(defun ein:$kernel-session-url (kernel)
  (concat "/api/sessions/" (ein:$kernel-session-id kernel)))

;;;###autoload
(defalias 'ein:kernel-url-or-port 'ein:$kernel-url-or-port)

;;;###autoload
(defalias 'ein:kernel-id 'ein:$kernel-kernel-id)

(make-obsolete-variable 'ein:pre-kernel-execute-functions nil "0.17.0")
(make-obsolete-variable 'ein:on-shell-reply-functions nil "0.17.0")
(make-obsolete-variable 'ein:on-kernel-connect-functions nil "0.17.0")

(defun ein:kernel-new (url-or-port path kernelspec base-url events &optional api-version)
  (make-ein:$kernel
   :url-or-port url-or-port
   :path path
   :kernelspec kernelspec
   :events events
   :api-version (or api-version 5)
   :session-id (ein:utils-uuid)
   :kernel-id nil
   :websocket nil
   :base-url base-url
   :oinfo-cache (make-hash-table :test #'equal)
   :username "username"
   :msg-callbacks (make-hash-table :test 'equal)
   :msg-progress (make-hash-table :test 'equal)))

(defun ein:kernel--set-status (kernel status)
  "Record STATUS (a symbol, see data-model.md) on KERNEL."
  (setf (ein:$kernel-status kernel) status))

(defun ein:kernel--note-execution-state (kernel status)
  "Record busy/idle STATUS from iopub unless KERNEL is restarting.
While a REST restart is in flight the old websocket still reports
the kernel's busy/idle cycle; only the reconnect may end `restarting'."
  (unless (eq (ein:$kernel-status kernel) 'restarting)
    (ein:kernel--set-status kernel status)))

;;; Ownership (FR-010): kernels whose session this Emacs created.

(defvar ein:kernel--owned (make-hash-table :test #'equal)
  "Kernel ids started by this Emacs through a session POST.")

(defun ein:kernel-owned-p (kernel-id)
  "Non-nil if KERNEL-ID was started by this Emacs."
  (and kernel-id (gethash kernel-id ein:kernel--owned)))

(defun ein:kernel-del (kernel)
  "Destructor for `ein:$kernel'."
  (ein:kernel-disconnect kernel))

(defun ein:kernel--get-msg (kernel msg-type content)
  (list
   :header (list
            :msg_id (ein:utils-uuid)
            :username (ein:$kernel-username kernel)
            :session (ein:$kernel-session-id kernel)
            :version "5.0"
            :date (format-time-string "%Y-%m-%dT%T" (current-time)) ; ISO 8601 timestamp
            :msg_type msg-type)
   :metadata (make-hash-table)
   :content content
   :parent_header (make-hash-table)))

(cl-defun ein:kernel-session-p (kernel callback &optional iteration)
  "Don't make any changes on the server side.  CALLBACK with arity
2, kernel and a boolean whether session exists on server."
  (unless iteration
    (setq iteration 0))
  (let ((session-id (ein:$kernel-session-id kernel)))
    (ein:query-singleton-ajax
     (ein:url (ein:$kernel-url-or-port kernel) "api/sessions" session-id)
     :type "GET"
     :parser #'ein:json-read
     :complete (apply-partially #'ein:kernel-session-p--complete session-id)
     :success (apply-partially #'ein:kernel-session-p--success kernel session-id callback)
     :error (apply-partially #'ein:kernel-session-p--error kernel callback iteration))))

(cl-defun ein:kernel-session-p--complete (_session-id
                                          &key data response
                                          &allow-other-keys
                                          &aux (resp-string (format "STATUS: %s DATA: %s" (request-response-status-code response) data)))
  (ein:log 'debug "ein:kernel-session-p--complete %s" resp-string))

(cl-defun ein:kernel-session-p--error (kernel callback iteration
                                       &key error-thrown _symbol-status data
                                       &allow-other-keys)
  (if (ein:aand (plist-get data :message) (cl-search "not found" it))
      (when callback (funcall callback kernel nil))
    (let* ((max-tries 3)
           (tries-left (1- (- max-tries iteration))))
      (ein:log 'verbose "ein:kernel-session-p--error [%s], %s tries left"
               (car error-thrown) tries-left)
      (if (> tries-left 0)
          (ein:kernel-session-p kernel callback (1+ iteration))))))

(cl-defun ein:kernel-session-p--success (kernel session-id callback
                                         &key data &allow-other-keys)
  (let ((session-p (equal (plist-get data :id) session-id)))
    (ein:log 'verbose "ein:kernel-session-p--success: session-id=%s session-p=%s"
             session-id session-p)
    (when callback (funcall callback kernel session-p))))

(defun ein:kernel--restart-by-recreate (kernel)
  "Legacy restart: delete KERNEL's session and create a new one.
The kernel id changes.  Used only when the server lacks the REST
restart endpoint."
  (ein:kernel-delete-session
   (lambda (kernel)
     (ein:events-trigger (ein:$kernel-events kernel) 'status_restarting.Kernel)
     (ein:kernel-retrieve-session kernel 0
                                  (lambda (kernel)
                                    (ein:events-trigger (ein:$kernel-events kernel)
                                                        'status_restarted.Kernel))))
   :kernel kernel :no-confirm t))

(cl-defun ein:kernel-restart-session (kernel)
  "Restart KERNEL with `POST /api/kernels/<id>/restart', keeping its id.
Falls back to session delete+recreate when the server answers 404 or 405."
  (let ((kernel-id (ein:$kernel-kernel-id kernel)))
    (if (not kernel-id)
        (ein:kernel--restart-by-recreate kernel)
      (ein:kernel--set-status kernel 'restarting)
      (ein:events-trigger (ein:$kernel-events kernel) 'status_restarting.Kernel)
      (ein:query-singleton-ajax
       (ein:url (ein:$kernel-url-or-port kernel) "api/kernels" kernel-id "restart")
       :type "POST"
       :parser #'ein:json-read
       :success (lambda (&rest _)
                  (ein:log 'verbose "ein:kernel-restart-session: restarted %s" kernel-id)
                  (ein:kernel--close-websocket kernel)
                  (ein:kernel-start-websocket
                   kernel
                   (lambda (kernel)
                     (ein:kernel--set-status kernel 'idle)
                     (ein:events-trigger (ein:$kernel-events kernel)
                                         'status_restarted.Kernel))))
       :error (cl-function
               (lambda (&key response error-thrown &allow-other-keys)
                 (let ((code (request-response-status-code response)))
                   (if (memq code '(404 405))
                       (progn
                         (ein:log 'info "REST restart unavailable (%s); recreating the session" code)
                         (ein:kernel--restart-by-recreate kernel))
                     (ein:kernel--set-status kernel 'dead)
                     (ein:log 'error "ein:kernel-restart-session: %s %s"
                              (or code "") (car error-thrown))))))))))

(cl-defun ein:kernel-retrieve-session (kernel &optional iteration callback)
  "Formerly ein:kernel-start, but that was a misnomer.

The server 1. really starts a session (and an accompanying
kernel), and 2. may not even start a session if one exists for
the same path.

If picking up from where we last left off, that is, we restart
emacs and reconnect to same server, jupyter will hand us back the
original, still running session.

CALLBACK of arity 1, the kernel."
;; The server logic is here (could not find other documentation)
;; https://github.com/jupyter/notebook/blob/04a686dbaf9dfe553324a03cb9e6f778cf1e3da1/notebook/services/sessions/handlers.py#L56-L81
  (unless iteration
    (setq iteration 0))
  (if (<= (ein:$kernel-api-version kernel) 2)
      (error "Api %s unsupported" (ein:$kernel-api-version kernel))
    (let ((kernel-id (ein:$kernel-kernel-id kernel))
          (kernelspec (ein:$kernel-kernelspec kernel))
          (path (ein:$kernel-path kernel)))
      (ein:kernel--set-status kernel 'starting)
      (ein:query-singleton-ajax
       (ein:url (ein:$kernel-url-or-port kernel) "api/sessions")
       :type "POST"
       :data (ein:json-encode
              `((path . ,path)
                (type . "notebook")
                ,@(if kernelspec
                      `((kernel .
                                ((name . ,(ein:$kernelspec-name kernelspec))
                                 ,@(if kernel-id
                                       `((id . ,kernel-id)))))))))
       :parser #'ein:json-read
       :complete (apply-partially #'ein:kernel-retrieve-session--complete kernel callback)
       :success (apply-partially #'ein:kernel-retrieve-session--success
                                 kernel callback :new-p (not kernel-id))
       :error (apply-partially #'ein:kernel-retrieve-session--error kernel iteration callback)))))

(cl-defun ein:kernel-retrieve-session--complete
    (_kernel _callback
     &key data response
     &allow-other-keys
     &aux (resp-string (format "STATUS: %s DATA: %s" (request-response-status-code response) data)))
  (ein:log 'debug "ein:kernel-retrieve-session--complete %s" resp-string))

(cl-defun ein:kernel-retrieve-session--error
    (kernel iteration callback
     &key error-thrown _symbol-status &allow-other-keys)
  (let* ((max-tries 3)
         (tries-left (1- (- max-tries iteration))))
    (ein:log 'verbose "ein:kernel-retrieve-session--error [%s], %s tries left"
             (car error-thrown) tries-left)
    (if (> tries-left 0)
        (ein:query--retry-later (* (1+ iteration) 0.5)
                                #'ein:kernel-retrieve-session
                                kernel (1+ iteration) callback))))

(cl-defun ein:kernel-retrieve-session--success (kernel callback
                                               &key new-p data &allow-other-keys)
  "NEW-P is non-nil when the session POST did not name an existing kernel."
  (let ((session-id (plist-get data :id)))
    (if (plist-get data :kernel)
        (setq data (plist-get data :kernel)))
    (cl-destructuring-bind (&key id &allow-other-keys) data
      (ein:log 'verbose "ein:kernel-retrieve-session--success: kernel-id=%s session-id=%s"
               id session-id)
      (setf (ein:$kernel-kernel-id kernel) id)
      (when (and new-p id)
        (puthash id t ein:kernel--owned))
      (setf (ein:$kernel-session-id kernel) session-id)
      (setf (ein:$kernel-ws-url kernel) (ein:kernel--ws-url (ein:$kernel-url-or-port kernel)))
      (setf (ein:$kernel-kernel-url kernel)
            (concat (file-name-as-directory (ein:$kernel-base-url kernel)) id)))
    (ein:kernel-start-websocket kernel callback)))

(defun ein:kernel-reconnect-session (kernel &optional callback)
  "If session does not already exist, prompt user to create a new session.
Otherwise, return extant session.
`ein:kernel-retrieve-session; both retrieves and creates.
CALLBACK takes one argument kernel (e.g., execute cell now that
we're reconnected)."
  (ein:kernel-disconnect kernel)
  (ein:kernel-session-p
   kernel
   (apply-partially
    (lambda (callback* kernel session-p)
      (when (or session-p
                (and (not noninteractive) (y-or-n-p "Session not found.  Restart?")))
        (ein:events-trigger (ein:$kernel-events kernel) 'status_reconnecting.Kernel)
        (ein:kernel-retrieve-session
         kernel 0
         (apply-partially
          (lambda (callback** kernel)
            (ein:events-trigger (ein:$kernel-events kernel)
                                'status_reconnected.Kernel)
            (when callback** (funcall callback** kernel)))
          callback*))))
    callback)))

(defun ein:kernel--ws-url (url-or-port)
  "Assuming URL-OR-PORT already normalized by `ein:url'.
See https://github.com/ipython/ipython/pull/3307"
  (let* ((parsed-url (url-generic-parse-url url-or-port))
         (protocol (if (string= (url-type parsed-url) "https") "wss" "ws")))
    ;; Drop the trailing slash of the base path: the kernel url that is
    ;; appended starts with "/" (C20: "ws://host//api/kernels" got 404).
    (format "%s://%s:%s%s"
            protocol
            (url-host parsed-url)
            (url-port parsed-url)
            (string-trim-right (url-filename parsed-url) "/+"))))

(defconst ein:kernel--known-msg-types
  '(("iopub" "stream" "display_data" "update_display_data" "pyout" "pyerr"
     "error" "execute_result" "status" "data_pub" "clear_output"
     "execute_input" "pyin" "comm_open" "comm_msg" "comm_close"
     "debug_event" "shutdown_reply")
    ("shell" "execute_reply" "inspect_reply" "object_info_reply"
     "complete_reply" "history_reply" "is_complete_reply" "kernel_info_reply"
     "connect_reply" "comm_info_reply" "shutdown_reply" "interrupt_reply"
     "debug_reply")
    ("stdin" "input_request"))
  "Message types each channel may carry (Jupyter messaging protocol 5.x).")

(defun ein:kernel--short-id (msg-id)
  (if (stringp msg-id) (substring msg-id 0 (min 8 (length msg-id))) msg-id))

(defun ein:kernel--pending-p (kernel msg-id)
  "Non-nil if MSG-ID is a request of KERNEL still awaiting replies."
  (and msg-id
       (not (eq (gethash msg-id (ein:$kernel-msg-callbacks kernel) 'ein--none)
                'ein--none))))

(defun ein:kernel--output-routes (kernel)
  "Output routes of KERNEL's finished requests: a cons of two tables.
The car maps a msg-id to its `:output' and `:clear_output' callbacks;
the cdr maps their owner (the cell) to its latest request's msg-id,
pending or finished: only that request keeps a route.  Kernels may send
output after the idle status (from background threads, say), so that
output still reaches its cell, until the cell runs again."
  (or (ein:$kernel-output-routes kernel)
      (setf (ein:$kernel-output-routes kernel)
            (cons (make-hash-table :test #'equal)
                  (make-hash-table :test #'eq)))))

(defun ein:kernel--callbacks-owner (callbacks)
  "The object CALLBACKS deliver output to, or nil."
  (let ((output (plist-get callbacks :output)))
    (and (consp output) (cdr output))))

(defun ein:kernel--set-latest (kernel owner msg-id)
  "Make MSG-ID OWNER's latest request on KERNEL, ending older routes."
  (when owner
    (let* ((routes (ein:kernel--output-routes kernel))
           (old (gethash owner (cdr routes))))
      (when old
        (remhash old (car routes)))
      (puthash owner msg-id (cdr routes)))))

(defun ein:kernel--keep-route (kernel msg-id callbacks)
  "Keep routing late output of the finished request MSG-ID to its owner,
unless the owner has run again since."
  (when-let* ((owner (ein:kernel--callbacks-owner callbacks)))
    (let ((routes (ein:kernel--output-routes kernel)))
      (when (equal msg-id (gethash owner (cdr routes)))
        (puthash msg-id (list :output (plist-get callbacks :output)
                              :clear_output (plist-get callbacks :clear_output))
                 (car routes))))))

(defun ein:kernel--msg-done (kernel msg-id what)
  "Record that WHAT (`reply' or `idle') arrived for MSG-ID.
Once both have arrived, the pending request is forgotten; only its
output route is kept, see `ein:kernel--output-routes'."
  (when (ein:kernel--pending-p kernel msg-id)
    (let* ((progress (ein:$kernel-msg-progress kernel))
           (seen (gethash msg-id progress)))
      (if (and seen (not (eq seen what)))
          (progn (remhash msg-id progress)
                 (ein:kernel--keep-route
                  kernel msg-id (ein:kernel-get-callbacks-for-msg kernel msg-id))
                 (remhash msg-id (ein:$kernel-msg-callbacks kernel)))
        (puthash msg-id what progress)))))

(defun ein:kernel--validate-message (kernel msg)
  "Return nil if MSG may be dispatched, else a reason string."
  (let* ((channel (plist-get msg :channel))
         (header (plist-get msg :header))
         (msg-type (and (listp header) (plist-get header :msg_type)))
         (parent-id (plist-get (plist-get msg :parent_header) :msg_id))
         (content (plist-get msg :content)))
    (cond ((not (stringp channel)) "no channel")
          ((not (assoc channel ein:kernel--known-msg-types))
           (format "unknown channel %s" channel))
          ((not (stringp msg-type)) "no header.msg_type")
          ((not (plist-member msg :parent_header)) "no parent_header")
          ((not (member msg-type (cdr (assoc channel ein:kernel--known-msg-types))))
           (format "unknown msg_type %s" msg-type))
          ((and (equal channel "shell")
                (not (ein:kernel--pending-p kernel parent-id)))
           (format "%s for unknown msg_id %s" msg-type (ein:kernel--short-id parent-id)))
          ((and (equal msg-type "stream") (not (stringp (plist-get content :text))))
           (format "stream without text for msg_id %s" (ein:kernel--short-id parent-id))))))

(defun ein:kernel--handle-websocket-reply (kernel _ws frame)
  "Dispatch the websocket FRAME to KERNEL's channel handlers.
Malformed or unexpected messages are logged at `warn' and dropped;
no error escapes into the websocket library (constitution VI)."
  (let ((packet (websocket-frame-payload frame))
        msg)
    (condition-case err
        (setq msg (ein:json-read-from-string packet))
      (error
       (ein:log 'warn "Dropped malformed kernel message (%s)" (car err))))
    (cond
     ((null msg))
     ((not (and (listp msg) (keywordp (car-safe msg))))
      (ein:log 'warn "Dropped kernel message that is not an object"))
     (t
      (let ((reason (ein:kernel--validate-message kernel msg)))
        (if reason
            (ein:log 'warn "Dropped kernel message: %s" reason)
          (condition-case err
              (let ((channel (plist-get msg :channel)))
                (cond ((string-equal channel "iopub")
                       (ein:kernel--handle-iopub-reply kernel packet))
                      ((string-equal channel "shell")
                       (ein:kernel--handle-shell-reply kernel packet))
                      ((string-equal channel "stdin")
                       (ein:kernel--handle-stdin-reply kernel packet))))
            (error
             (ein:log 'error "Error handling %s message: %s"
                      (plist-get (plist-get msg :header) :msg_type)
                      (error-message-string err))))))))))

(defun ein:kernel--on-ws-close (ws)
  "Websocket WS closed.  If the client did not ask for it, disconnect.
Sets the kernel status to `disconnected' and emits
`status_disconnected.Kernel'; never reconnects by itself (FR-009)."
  (condition-case err
      (-if-let* ((websocket (websocket-client-data ws))
                 (kernel (ein:$websocket-kernel websocket)))
          (unless (ein:$websocket-closed-by-client websocket)
            (ein:log 'verbose "WS closed unexpectedly: %s" (websocket-url ws))
            (ein:kernel-disconnect kernel))
        (ein:log 'error "ein:start-single-websocket: on-close no client data for %s."
                 (websocket-url ws)))
    (error (ein:log 'error "ein:kernel--on-ws-close: %s" (error-message-string err)))))

(defun ein:start-single-websocket (kernel open-callback)
  "OPEN-CALLBACK (kernel) (e.g., execute cell)"
  (let ((ws-url (concat (ein:$kernel-ws-url kernel)
                         (ein:$kernel-kernel-url kernel)
                         "/channels?session_id="
                         (ein:$kernel-session-id kernel))))
    (ein:log 'verbose "WS start: %s" ws-url)
    (setf (ein:$kernel-websocket kernel)
          (ein:websocket ws-url kernel
                         (apply-partially #'ein:kernel--handle-websocket-reply kernel)
                         #'ein:kernel--on-ws-close
                         (apply-partially
                          (lambda (cb ws)
                            (-if-let* ((websocket (websocket-client-data ws))
                                       (kernel (ein:$websocket-kernel websocket)))
                                (progn
                                  (when (memq (ein:$kernel-status kernel)
                                              '(nil starting disconnected))
                                    (ein:kernel--set-status kernel 'idle))
                                  (awhen (and (ein:kernel-live-p kernel) cb)
                                    (funcall it kernel))
                                  (ein:log 'verbose "WS opened: %s" (websocket-url ws)))
                              (ein:log 'error "ein:start-single-websocket: on-open no client data for %s." (websocket-url ws))))
                          open-callback)))))

(defun ein:kernel-start-websocket (kernel callback)
  (cond ((<= (ein:$kernel-api-version kernel) 2)
         (error "Api version %s unsupported" (ein:$kernel-api-version kernel)))
        (t (ein:start-single-websocket kernel callback))))

(defun ein:kernel-on-connect (_kernel _content _metadata)
  (ein:log 'info "Kernel connect_request_reply received."))

(defun ein:kernel--close-websocket (kernel)
  "Close KERNEL's websocket, if any, without emitting events."
  (aif (ein:$kernel-websocket kernel)
      (progn (when (ein:$websocket-ws it)
               (ein:websocket-close it))
             (setf (ein:$kernel-websocket kernel) nil))))

(defun ein:kernel-disconnect (kernel)
  "Close websocket connection to running kernel, but do not
delete the kernel on the server side"
  (ein:kernel--set-status kernel 'disconnected)
  (ein:events-trigger (ein:$kernel-events kernel) 'status_disconnected.Kernel)
  (ein:kernel--close-websocket kernel))

(defun ein:kernel-live-p (kernel)
  (and (ein:$kernel-p kernel)
       (ein:aand (ein:$kernel-websocket kernel) (ein:websocket-open-p it))))

(defun ein:kernel-when-ready (kernel callback)
  "Execute CALLBACK of arity 1 (the kernel) when KERNEL is ready.
Warn user otherwise."
  (if (ein:kernel-live-p kernel)
      (funcall callback kernel)
    (ein:log 'verbose "Kernel %s unavailable" (ein:$kernel-kernel-id kernel))
    (ein:kernel-reconnect-session kernel callback)))

(defun ein:kernel-object-info-request (kernel objname callbacks &optional cursor-pos detail-level)
  "Send object info request of OBJNAME to KERNEL.

When calling this method pass a CALLBACKS structure of the form:

    (:object_info_reply (FUNCTION . ARGUMENT))

Call signature::

  (`funcall' FUNCTION ARGUMENT CONTENT METADATA)

CONTENT and METADATA are given by `object_info_reply' message.

`object_info_reply' message is documented here:
http://ipython.org/ipython-doc/dev/development/messaging.html#object-information
"
  (cl-assert (ein:kernel-live-p kernel) nil "object_info_reply: Kernel is not active.")
  (when objname
    (if (<= (ein:$kernel-api-version kernel) 2)
        (error "Api version %s unsupported" (ein:$kernel-api-version kernel)))
    (let* ((content (if (< (ein:$kernel-api-version kernel) 5)
                        (list
                         ;; :text ""
                         :oname (format "%s" objname)
                         :cursor_pos (or cursor-pos 0)
                         :detail_level (or detail-level 0))
                      (list
                       :code (format "%s" objname)
                       :cursor_pos (or cursor-pos 0)
                       :detail_level (or detail-level 0))))
           (msg (ein:kernel--get-msg kernel "inspect_request"
                                     (append content (list :detail_level 1))))
           (msg-id (plist-get (plist-get msg :header) :msg_id)))
      (ein:websocket-send-shell-channel kernel msg)
      (ein:kernel-set-callbacks-for-msg kernel msg-id callbacks))))

(defun ein:kernel-complete (kernel code cursor-pos callback)
  "Send a `complete_request' for CODE at CURSOR-POS to KERNEL.
CURSOR-POS counts characters from the start of CODE.  CALLBACK is
called with the `complete_reply' content.  Return the message id."
  (cl-assert (ein:kernel-live-p kernel) nil "complete_request: Kernel is not active.")
  (let* ((msg (ein:kernel--get-msg kernel "complete_request"
                                   (list :code code :cursor_pos cursor-pos)))
         (msg-id (plist-get (plist-get msg :header) :msg_id)))
    (ein:kernel-set-callbacks-for-msg
     kernel msg-id
     (list :complete_reply
           (cons (lambda (cb content _metadata) (funcall cb content)) callback)))
    (ein:websocket-send-shell-channel kernel msg)
    msg-id))

(cl-defun ein:kernel-execute (kernel code &optional callbacks
                              &key
                              (silent t)
                              (store-history t)
                              (user-expressions (make-hash-table))
                              (allow-stdin t)
                              (stop-on-error nil))
  "Execute CODE on KERNEL.

The CALLBACKS plist looks like:

  (:execute_reply  EXECUTE-REPLY-CALLBACK
   :output         OUTPUT-CALLBACK
   :clear_output   CLEAR-OUTPUT-CALLBACK
   :set_next_input SET-NEXT-INPUT)

Right hand sides ending -CALLBACK above are of the form (FUNCTION
ARG1 ... ARGN).

(Hindsight: this was all much better implemented using `apply-partially')

Return randomly generated MSG-ID tag uniquely identifying
expectation of a kernel response."
  (cl-assert (ein:kernel-live-p kernel) nil "execute_reply: Kernel is not active.")
  (let* ((content (list
                   :code code
                   :silent (or silent json-false)
                   :store_history (or store-history json-false)
                   :user_expressions user-expressions
                   :allow_stdin allow-stdin
                   :stop_on_error (or stop-on-error json-false)))
         (msg (ein:kernel--get-msg kernel "execute_request" content))
         (msg-id (plist-get (plist-get msg :header) :msg_id)))
    (if ein:log-include-code
        (ein:log 'debug "ein:kernel-execute: code=%s msg_id=%s" code msg-id)
      (ein:log 'debug "ein:kernel-execute: msg_id=%s" msg-id))
    (ein:websocket-send-shell-channel kernel msg)
    (ein:kernel-set-callbacks-for-msg kernel msg-id callbacks)
    (unless silent
      (mapc #'ein:funcall-packed
            (ein:$kernel-after-execute-hook kernel)))
    msg-id))

(defun ein:kernel-connect-request (kernel callbacks)
  "Request basic information for a KERNEL.

When calling this method pass a CALLBACKS structure of the form::

  (:connect_reply (FUNCTION . ARGUMENT))

Call signature::

  (`funcall' FUNCTION ARGUMENT CONTENT METADATA)

CONTENT and METADATA are given by `kernel_info_reply' message.

`connect_request' message is documented here:
http://ipython.org/ipython-doc/dev/development/messaging.html#connect

Example::

  (ein:kernel-connect-request
   (ein:get-kernel)
   \\='(:kernel_connect_reply (message . \"CONTENT: %S\\nMETADATA: %S\")))
"
  ;(cl-assert (ein:kernel-live-p kernel) nil "connect_reply: Kernel is not active.")
  (let* ((msg (ein:kernel--get-msg kernel "connect_request" (make-hash-table)))
         (msg-id (plist-get (plist-get msg :header) :msg_id)))
    (ein:websocket-send-shell-channel kernel msg)
    (ein:kernel-set-callbacks-for-msg kernel msg-id callbacks)
    msg-id))

(defun ein:kernel-interrupt (kernel)
  (when (ein:kernel-live-p kernel)
    (ein:log 'info "Interrupting kernel")
    (ein:query-singleton-ajax
     (ein:url (ein:$kernel-url-or-port kernel)
              (ein:$kernel-kernel-url kernel)
              "interrupt")
     :type "POST"
     :success (lambda (&rest _ignore)
                (ein:log 'info "Sent interruption command.")))))

(defvar ein:force-sync)
(declare-function ein:content-query-sessions "ein-contents-api")
(defun ein:kernel--sessions-using (url-or-port kernel-id)
  "Number of sessions on URL-OR-PORT that use KERNEL-ID (synchronous)."
  (let ((sharing 0))
    (ein:query-singleton-ajax
     (ein:url url-or-port "api/sessions")
     :type "GET"
     :parser #'ein:json-read
     :sync t
     :success (cl-function
               (lambda (&key data &allow-other-keys)
                 (setq sharing
                       (cl-count kernel-id (append data nil)
                                 :key (lambda (s) (plist-get (plist-get s :kernel) :id))
                                 :test #'equal)))))
    sharing))

(defun ein:kernel--shutdown-confirmed-p (url-or-port kernel-id)
  "Return non-nil if the kernel KERNEL-ID may be shut down.
Ask first when this Emacs did not start it, or when more than one
session on URL-OR-PORT uses it (FR-010)."
  (cond ((not (ein:kernel-owned-p kernel-id))
         (y-or-n-p "Kernel not started by this Emacs; shut it down anyway? "))
        ((> (ein:kernel--sessions-using url-or-port kernel-id) 1)
         (y-or-n-p "Kernel is shared with other sessions; shut it down anyway? "))
        (t t)))

(cl-defun ein:kernel-delete-session (&optional callback
                                     &key url-or-port path kernel no-confirm
                                     &aux (session-id) (kernel-id))
  "Regardless of success or error, we clear all state variables of
kernel and funcall CALLBACK (kernel).
Unless NO-CONFIRM, ask before shutting down a kernel this Emacs did
not start or that other sessions share; on refusal only disconnect."
  (cond (kernel
         (setq url-or-port (ein:$kernel-url-or-port kernel))
         (setq path (ein:$kernel-path kernel))
         (setq session-id (ein:$kernel-session-id kernel))
         (setq kernel-id (ein:$kernel-kernel-id kernel)))
        ((and url-or-port path)
         (aif (ein:notebook-get-opened-notebook url-or-port path)
             (progn
               (setq kernel (ein:$notebook-kernel it))
               (setq session-id (ein:$kernel-session-id kernel))
               (setq kernel-id (ein:$kernel-kernel-id kernel)))
           (let ((ein:force-sync t))
             (ein:content-query-sessions
              url-or-port
              (lambda (session-hash)
                (let ((entry (gethash path session-hash)))
                  (setq session-id (car entry))
                  (setq kernel-id (plist-get (cdr entry) :id))))
              nil))))
        (t (error "ein:kernel-delete-session: need kernel, or url-or-port and path")))
  (when (and session-id (not no-confirm)
             (not (ein:kernel--shutdown-confirmed-p url-or-port kernel-id)))
    (ein:log 'info "Kept kernel %s running; disconnected only" (or kernel-id ""))
    (setq session-id nil))
  (if session-id
      (ein:query-singleton-ajax
       (ein:url url-or-port "api/sessions" session-id)
       :type "DELETE"
       :complete (apply-partially #'ein:kernel-delete-session--complete kernel session-id callback)
       :error (apply-partially #'ein:kernel-delete-session--error session-id nil)
       :success (apply-partially #'ein:kernel-delete-session--success session-id
                                 (aif (ein:notebooklist-get-buffer url-or-port)
                                     (buffer-local-value 'ein:%notebooklist% it))
                                 nil))
    (ein:log 'verbose "ein:kernel-delete-session: no session deleted for %s" path)
    (when kernel
      (ein:kernel-disconnect kernel))
    (when callback
      (funcall callback kernel))))

(cl-defun ein:kernel-delete-session--error (session-id _callback
                                            &key _response error-thrown
                                            &allow-other-keys)
  (ein:log 'error "ein:kernel-delete-session--error %s: ERROR %s DATA %s"
           session-id (car error-thrown) (cdr error-thrown)))

(cl-defun ein:kernel-delete-session--success (session-id nblist _callback
                                              &key _data _symbol-status _response
                                              &allow-other-keys)
  (ein:log 'verbose "ein:kernel-delete-session--success: %s deleted" session-id)
  (when nblist
    (ein:notebooklist-reload nblist)))

(cl-defun ein:kernel-delete-session--complete (kernel _session-id callback
                                               &key data response
                                               &allow-other-keys
                                               &aux (resp-string (format "STATUS: %s DATA: %s" (request-response-status-code response) data)))
  (ein:log 'verbose "ein:kernel-delete-session--complete %s" resp-string)
  (when kernel
    (ein:kernel-disconnect kernel))
  (when callback (funcall callback kernel)))

;; Reply handlers.
(defun ein:kernel-get-callbacks-for-msg (kernel msg-id)
  (gethash msg-id (ein:$kernel-msg-callbacks kernel)))

(defun ein:kernel-set-callbacks-for-msg (kernel msg-id callbacks)
  "Set up promise for MSG-ID.
A new request of the same owner ends the route of its previous one."
  (ein:kernel--set-latest kernel (ein:kernel--callbacks-owner callbacks) msg-id)
  (puthash msg-id callbacks (ein:$kernel-msg-callbacks kernel)))

(defun ein:kernel--handle-stdin-reply (kernel packet)
  (cl-destructuring-bind
      (&key header _parent_header _metadata content &allow-other-keys)
      (ein:json-read-from-string packet)
    (let ((msg-type (plist-get header :msg_type))
          (msg-id (plist-get header :msg_id))
          (password (plist-get content :password)))
      (ein:log 'debug "ein:kernel--handle-stdin-reply: msg_type=%s msg_id=%s"
               msg-type msg-id)
      (cond ((string-equal msg-type "input_request")
             (if (not (eql password :json-false))
                 (let* ((passwd (read-passwd (plist-get content :prompt)))
                        (content (list :value passwd))
                        (msg (ein:kernel--get-msg kernel "input_reply" content)))
                   (ein:websocket-send-stdin-channel kernel msg))
               (cond ((string-match "^\\(ipdb> \\|(Pdb) \\)"
                                    (plist-get content :prompt))
                      (aif (ein:ipdb-get-session kernel)
                          (pop-to-buffer (ein:$ipdb-session-buffer it))
                        (let* ((url-or-port (ein:$kernel-url-or-port kernel))
                               (path (ein:$kernel-path kernel))
                               (notebook (ein:notebook-get-opened-notebook
                                          url-or-port path)))
                          (ein:ipdb-start-session
                           kernel
                           (match-string 1 (plist-get content :prompt))
                           notebook))))
                     (t (let* ((in (read-string (plist-get content :prompt)))
                               (content (list :value in))
                               (msg (ein:kernel--get-msg kernel "input_reply" content)))
                          (ein:websocket-send-stdin-channel kernel msg))))))))))

(defun ein:kernel--handle-payload (kernel callbacks payload)
  (cl-loop with events = (ein:$kernel-events kernel)
           for p in (append payload nil)
           for text = (or (plist-get p :text) (plist-get (plist-get p :data) :text/plain))
           for source = (plist-get p :source)
           if (member source '("IPython.kernel.zmq.page.page"
                               "IPython.zmq.page.page"
                               "page"))
           do (unless (equal (ein:trim text) "")
		(ein:events-trigger
		 events 'open_with_text.Pager (list :text text)))
           else if
           (member
            source
            '("IPython.kernel.zmq.zmqshell.ZMQInteractiveShell.set_next_input"
              "IPython.zmq.zmqshell.ZMQInteractiveShell.set_next_input"
              "set_next_input"))
           do (let ((cb (plist-get callbacks :set_next_input)))
		(when cb (ein:funcall-packed cb text)))))

(defun ein:kernel--handle-shell-reply (kernel packet)
  (cl-destructuring-bind
      (&key header content metadata parent_header &allow-other-keys)
      (ein:json-read-from-string packet)
    (let* ((msg-type (plist-get header :msg_type))
           (msg-id (plist-get parent_header :msg_id))
           (callbacks (ein:kernel-get-callbacks-for-msg kernel msg-id)))
      (ein:log 'debug "ein:kernel--handle-shell-reply: msg_type=%s msg_id=%s"
               msg-type msg-id)
      (aif (plist-get callbacks (intern-soft (format ":%s" msg-type)))
          (ein:funcall-packed it content metadata)
        (ein:log 'info "ein:kernel--handle-shell-reply: No :%s callback for msg_id=%s"
                 msg-type msg-id))
      (aif (plist-get content :payload)
          (ein:kernel--handle-payload kernel callbacks it))
      (let ((events (ein:$kernel-events kernel)))
        (ein:case-equal msg-type
          (("execute_reply")
           (aif (plist-get content :execution_count)
               (ein:events-trigger events 'execution_count.Kernel it)))))
      (ein:kernel--msg-done kernel msg-id 'reply))))

(defun ein:kernel--handle-iopub-reply (kernel packet)
  (cl-destructuring-bind
      (&key content metadata parent_header header &allow-other-keys)
      (ein:json-read-from-string packet)
    (let* ((msg-type (plist-get header :msg_type))
           (msg-id (plist-get header :msg_id))
           (parent-id (plist-get parent_header :msg_id))
           (callbacks (or (ein:kernel-get-callbacks-for-msg kernel parent-id)
                          (and parent-id
                               (gethash parent-id
                                        (car (ein:kernel--output-routes kernel))))))
           (events (ein:$kernel-events kernel)))
      (ein:log 'debug
        "ein:kernel--handle-iopub-reply: msg_type=%s msg_id=%s parent_id=%s"
        msg-type msg-id parent-id)
      (ein:case-equal msg-type
        (("stream" "display_data" "update_display_data" "pyout" "pyerr" "error"
          "execute_result")
         (aif (plist-get callbacks :output) ;; ein:cell--handle-output
             (ein:funcall-packed it msg-type content metadata)
           (ein:log 'warn (concat "ein:kernel--handle-iopub-reply: "
                                  "No :output callback for parent_id=%s")
                    parent-id))
         (when (ein:ipdb-get-session kernel)
           (ein:ipdb--handle-iopub-reply kernel packet)))
        (("status")
         (ein:case-equal (plist-get content :execution_state)
           (("busy")
            (ein:kernel--note-execution-state kernel 'busy)
            (ein:events-trigger events 'status_busy.Kernel))
           (("idle")
            (ein:kernel--note-execution-state kernel 'idle)
            (ein:events-trigger events 'status_idle.Kernel)
            (awhen (ein:ipdb-get-session kernel)
              (ein:ipdb-stop-session it))
            (ein:kernel--msg-done kernel parent-id 'idle))
           (("restarting" "autorestarting")
            ;; Jupyter Server's auto-restarter: the kernel process died
            ;; and a fresh one is starting.  Output of running cells is
            ;; lost; a later idle marks the new kernel usable.
            (unless (eq (ein:$kernel-status kernel) 'restarting)
              (ein:log 'warn "Kernel %s died; the server is restarting it"
                       (ein:$kernel-kernel-id kernel))
              (ein:kernel--set-status kernel 'dead)
              (ein:events-trigger events 'status_dead.Kernel)))
           (("dead")
            (ein:kernel-disconnect kernel)
            (ein:kernel--set-status kernel 'dead)
            (awhen (ein:ipdb-get-session kernel)
              (ein:ipdb-stop-session it)))))
        (("data_pub")
         (ein:log 'verbose "ein:kernel--handle-iopub-reply: data_pub %S" packet))
        (("clear_output")
         (aif (plist-get callbacks :clear_output)
             (ein:funcall-packed it content metadata)
           (ein:log 'info (concat "ein:kernel--handle-iopub-reply: "
                                  "No :clear_output callback for parent_id=%s")
                    parent-id)))))))

(provide 'ein-kernel)

;;; ein-kernel.el ends here
