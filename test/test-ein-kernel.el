;; -*- lexical-binding:t -*-

(require 'ert)

(require 'ein-kernel)
(require 'ein-testing-notebook)

(defun eintest:kernel-new (port)
  (ein:kernel-new port "" nil "/api/kernels"
                  (get-buffer-create "*eintest: dummy for kernel test*")))

(ert-deftest ein:kernel-restart-check-url ()
  (let* ((notebook (ein:notebook-new ein:testing-notebook-dummy-url "" nil))
         (kernel (eintest:kernel-new 8888))
         (kernel-id "KERNEL-ID")
         ;; Restart is POST /api/kernels/<id>/restart (C17), not session recreate.
         (desired-url "http://127.0.0.1:8888/api/kernels/KERNEL-ID/restart")
         (dummy-response (make-request-response))
         got-url)
    (setf (ein:$notebook-kernel notebook) kernel)
    (cl-letf (((symbol-function 'request)
               (lambda (url &rest _ignore) (setq got-url url) dummy-response))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'ein:kernel-stop-channels) #'ignore)
              ((symbol-function 'ein:websocket) (lambda (&rest _ignore) (make-ein:$websocket :ws nil :kernel kernel :closed-by-client nil)))
              ((symbol-function 'ein:events-trigger) #'ignore)
              ((symbol-function 'ein:get-notebook-or-error) (lambda () (ein:get-notebook))))
      (ein:kernel-retrieve-session--success
       kernel nil :data (list :ws_url "ws://127.0.0.1:8888" :id kernel-id))
      (ein:kernel-restart-session (ein:$notebook-kernel notebook))
      (should (equal got-url desired-url)))))

(ert-deftest ein:kernel-interrupt-check-url ()
  (let* ((kernel (eintest:kernel-new 8888))
         (kernel-id "KERNEL-ID")
         (desired-url "http://127.0.0.1:8888/api/kernels/KERNEL-ID/interrupt")
         (dummy-response (make-request-response))
         got-url)

    (cl-letf (((symbol-function 'request)
               (lambda (url &rest _ignore) (setq got-url url) dummy-response))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'ein:kernel-stop-channels) #'ignore)
              ((symbol-function 'ein:websocket) (lambda (&rest _ignore) (make-ein:$websocket :ws nil :kernel kernel :closed-by-client nil)))
              ((symbol-function 'ein:websocket-open-p) (lambda (&rest _ignore) t)))
      (ein:kernel-retrieve-session--success
       kernel nil :data (list :ws_url "ws://127.0.0.1:8888" :id kernel-id))
      (ein:kernel-interrupt kernel)
      (should (equal got-url desired-url)))))

(ert-deftest ein:kernel-kill-check-url ()
  (let* ((kernel (eintest:kernel-new 8888))
         (kernel-id "KERNEL-ID")
         (desired-url "http://127.0.0.1:8888/api/sessions/KERNEL-ID")
         (dummy-response (make-request-response))
         got-url)
    (cl-letf (((symbol-function 'request)
               (lambda (url &rest _ignore) (setq got-url url) dummy-response))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'ein:kernel-stop-channels) #'ignore)
              ((symbol-function 'ein:websocket)
               (lambda (&rest _ignore) (make-ein:$websocket :ws nil :kernel kernel
                                                           :closed-by-client nil)))
              ((symbol-function 'ein:websocket-open-p) (lambda (&rest _ignore) t)))
      ;; :new-p t: this Emacs started the kernel, so no confirmation (T049).
      (ein:kernel-retrieve-session--success
       kernel nil :new-p t :data (list :ws_url "ws://127.0.0.1:8888" :id kernel-id))
      (ein:kernel-delete-session nil :kernel kernel))
    (should (equal got-url desired-url))))

;;; US2 (T030, T031, T037, T038)

(require 'ein-events)

(defun eintest:kernel-live (&optional sent)
  "Return a kernel that looks live; outgoing messages are pushed to SENT."
  (let ((kernel (ein:kernel-new 8888 "" nil "/api/kernels" (ein:events-new))))
    (setf (ein:$kernel-websocket kernel)
          (make-ein:$websocket :ws nil :kernel kernel :closed-by-client nil))
    (setf (ein:$kernel-kernel-id kernel) "KID")
    (ignore sent)
    kernel))

(defmacro eintest:with-live-kernel (kernel-var sent-var &rest body)
  (declare (indent 2))
  `(let* ((,sent-var (list))
          (,kernel-var (eintest:kernel-live)))
     (cl-letf (((symbol-function 'ein:websocket-open-p) (lambda (&rest _) t))
               ((symbol-function 'ein:websocket-send-shell-channel)
                (lambda (_k msg) (push msg ,sent-var)))
               ((symbol-function 'ein:websocket-close) #'ignore))
       ,@body)))

(defun eintest:frame (plist)
  (make-websocket-frame :opcode 'text :payload (ein:json-encode plist)))

(defun eintest:msg (channel msg-type parent-id content)
  (list :channel channel
        :header (list :msg_id (ein:utils-uuid) :msg_type msg-type)
        :parent_header (if parent-id (list :msg_id parent-id) (make-hash-table))
        :metadata (make-hash-table)
        :content content))

(defmacro eintest:capturing-logs (logs-var &rest body)
  "Run BODY, collecting (LEVEL . MESSAGE) of `ein:log-wrapper' in LOGS-VAR."
  (declare (indent 1))
  `(let ((,logs-var '()))
     (cl-letf (((symbol-function 'ein:log-wrapper)
                (lambda (level func) (push (cons level (funcall func)) ,logs-var))))
       ,@body)))

(ert-deftest ein:kernel-execute-does-not-log-code ()
  (eintest:with-live-kernel kernel _sent
    (eintest:capturing-logs logs
      (let ((ein:log-include-code nil))
        (ein:kernel-execute kernel "print('very-secret-code')"))
      (should-not (cl-some (lambda (l) (string-search "very-secret-code" (cdr l))) logs)))
    (eintest:capturing-logs logs
      (let ((ein:log-include-code t))
        (ein:kernel-execute kernel "print('very-secret-code')"))
      (should (cl-some (lambda (l) (string-search "very-secret-code" (cdr l))) logs)))))

(ert-deftest ein:kernel-unexpected-close-sets-disconnected ()
  (eintest:with-live-kernel kernel _sent
    (let ((websocket (ein:$kernel-websocket kernel)))
      (let ((ws (websocket-inner-create :url "ws://127.0.0.1:8888/x"
                                        :conn nil :client-data websocket)))
        (ein:kernel--on-ws-close ws)
        (should (eq (ein:$kernel-status kernel) 'disconnected))))))

(defun eintest:kernel-snapshot (kernel)
  (let (keys)
    (maphash (lambda (k v) (push (cons k (copy-tree v)) keys))
             (ein:$kernel-msg-callbacks kernel))
    (list (ein:$kernel-status kernel) (sort keys (lambda (a b) (string< (car a) (car b)))))))

(ert-deftest ein:kernel-malformed-messages ()
  (eintest:with-live-kernel kernel _sent
    (let* ((outputs '())
           (msg-id (ein:kernel-execute
                    kernel "x"
                    (list :output (cons (lambda (_arg &rest args) (push args outputs)) nil)
                          :execute_reply (cons (lambda (_arg &rest args) (push args outputs)) nil))))
           (inputs
            (list
             "{not json"
             (ein:json-encode (list :channel "shell" :content (list :status "ok")))
             (ein:json-encode (eintest:msg "iopub" "x_unknown_type" msg-id (list :a 1)))
             (ein:json-encode (eintest:msg "shell" "execute_reply" "no-such-msg-id"
                                           (list :status "ok" :execution_count 1)))
             (ein:json-encode (eintest:msg "iopub" "stream" msg-id (list :name "stdout"))))))
      (dolist (packet inputs)
        (let ((before (eintest:kernel-snapshot kernel)))
          (eintest:capturing-logs logs
            (ein:kernel--handle-websocket-reply
             kernel nil (make-websocket-frame :opcode 'text :payload packet))
            (should (assq 'warn logs)))
          (should (equal (eintest:kernel-snapshot kernel) before))
          (should (null outputs)))))))

(ert-deftest ein:kernel-out-of-order-routing ()
  (eintest:with-live-kernel kernel sent
    (let* ((a '()) (b '())
           (cb (lambda (sym)
                 (list :output (cons (lambda (_ _type content _md)
                                       (set sym (cons (or (plist-get content :text)
                                                          (plist-get (plist-get content :data)
                                                                     :text/plain))
                                                      (symbol-value sym))))
                                     nil)
                       :execute_reply (cons (lambda (_ content _md)
                                              (set sym (cons (list 'reply (plist-get content :status))
                                                             (symbol-value sym))))
                                            nil))))
           (_ (progn (defvar eintest--a) (defvar eintest--b)
                     (setq eintest--a nil eintest--b nil)))
           (id-a (ein:kernel-execute kernel "a" (funcall cb 'eintest--a)))
           (id-b (ein:kernel-execute kernel "b" (funcall cb 'eintest--b))))
      (should (= (length sent) 2))
      (dolist (m (list (eintest:msg "iopub" "status" id-b '(:execution_state "busy"))
                       (eintest:msg "iopub" "status" id-a '(:execution_state "busy"))
                       (eintest:msg "iopub" "stream" id-b '(:name "stdout" :text "b1"))
                       (eintest:msg "iopub" "execute_result" id-a
                                    '(:execution_count 1 :data (:text/plain "a1") :metadata nil))
                       (eintest:msg "shell" "execute_reply" id-b '(:status "ok" :execution_count 2))
                       (eintest:msg "iopub" "stream" id-a '(:name "stdout" :text "a2"))
                       (eintest:msg "shell" "execute_reply" id-a '(:status "ok" :execution_count 1))
                       (eintest:msg "iopub" "status" id-b '(:execution_state "idle"))
                       (eintest:msg "iopub" "status" id-a '(:execution_state "idle"))))
        (ein:kernel--handle-websocket-reply kernel nil (eintest:frame m)))
      (setq a eintest--a b eintest--b)
      (should (equal (reverse a) '("a1" "a2" (reply "ok"))))
      (should (equal (reverse b) '("b1" (reply "ok"))))
      (should-not (ein:kernel-get-callbacks-for-msg kernel id-a))
      (should-not (ein:kernel-get-callbacks-for-msg kernel id-b)))))

(ert-deftest ein:kernel-late-output-reaches-cell ()
  "Output after the reply and idle still reaches its owner, until it runs again."
  (eintest:with-live-kernel kernel _sent
    (let* ((got '())
           (owner (list 'cell))
           (callbacks (lambda ()
                        (list :output (cons (lambda (_ _type content _md)
                                              (push (plist-get content :text) got))
                                            owner)
                              :execute_reply (cons #'ignore owner))))
           (deliver (lambda (&rest msgs)
                      (dolist (m msgs)
                        (ein:kernel--handle-websocket-reply kernel nil (eintest:frame m)))))
           (id-1 (ein:kernel-execute kernel "a" (funcall callbacks))))
      (funcall deliver
               (eintest:msg "shell" "execute_reply" id-1 '(:status "ok" :execution_count 1))
               (eintest:msg "iopub" "status" id-1 '(:execution_state "idle"))
               (eintest:msg "iopub" "stream" id-1 '(:name "stdout" :text "late")))
      (should (equal got '("late")))
      ;; The finished request no longer counts as pending.
      (should-not (ein:kernel-get-callbacks-for-msg kernel id-1))
      ;; Running the owner again ends the route of its previous request.
      (let ((id-2 (ein:kernel-execute kernel "b" (funcall callbacks))))
        (eintest:capturing-logs _logs
          (funcall deliver (eintest:msg "iopub" "stream" id-1 '(:name "stdout" :text "stale"))))
        (funcall deliver (eintest:msg "iopub" "stream" id-2 '(:name "stdout" :text "new")))
        (should (equal got '("new" "late")))))))

(ert-deftest ein:kernel-superseded-request-keeps-no-route ()
  "A request that finishes after its cell ran again does not route output.
Run A, run the same cell as B, then let A finish: A's late output must
not land among B's results."
  (eintest:with-live-kernel kernel _sent
    (let* ((got '())
           (owner (list 'cell))
           (callbacks (lambda ()
                        (list :output (cons (lambda (_ _type content _md)
                                              (push (plist-get content :text) got))
                                            owner)
                              :execute_reply (cons #'ignore owner))))
           (deliver (lambda (&rest msgs)
                      (dolist (m msgs)
                        (ein:kernel--handle-websocket-reply kernel nil (eintest:frame m)))))
           (id-a (ein:kernel-execute kernel "a" (funcall callbacks)))
           (id-b (ein:kernel-execute kernel "b" (funcall callbacks))))
      (funcall deliver
               (eintest:msg "shell" "execute_reply" id-a '(:status "ok" :execution_count 1))
               (eintest:msg "iopub" "status" id-a '(:execution_state "idle")))
      (eintest:capturing-logs _logs
        (funcall deliver (eintest:msg "iopub" "stream" id-a '(:name "stdout" :text "stale"))))
      (funcall deliver (eintest:msg "iopub" "stream" id-b '(:name "stdout" :text "new")))
      (should (equal got '("new")))
      ;; B, the latest, keeps its route once it finishes.
      (funcall deliver
               (eintest:msg "shell" "execute_reply" id-b '(:status "ok" :execution_count 2))
               (eintest:msg "iopub" "status" id-b '(:execution_state "idle"))
               (eintest:msg "iopub" "stream" id-b '(:name "stdout" :text "late")))
      (should (equal got '("late" "new"))))))

(ert-deftest ein:kernel-complete-request-and-reply ()
  "T112: `ein:kernel-complete' sends complete_request and dispatches its reply."
  (eintest:with-live-kernel kernel sent
    (let* (got
           (id (ein:kernel-complete kernel "import o" 8 (lambda (c) (setq got c))))
           (msg (car sent)))
      (should (= 1 (length sent)))
      (should (equal "complete_request" (plist-get (plist-get msg :header) :msg_type)))
      (should (equal "import o" (plist-get (plist-get msg :content) :code)))
      (should (equal 8 (plist-get (plist-get msg :content) :cursor_pos)))
      (ein:kernel--handle-websocket-reply
       kernel nil
       (eintest:frame (eintest:msg "shell" "complete_reply" id
                                   '(:status "ok" :matches ["os" "open"]
                                     :cursor_start 7 :cursor_end 8))))
      (should (equal "ok" (plist-get got :status)))
      (should (equal ["os" "open"] (plist-get got :matches)))))
  (let ((kernel (ein:kernel-new 8888 "" nil "/api/kernels" (ein:events-new))))
    (should-error (ein:kernel-complete kernel "x" 1 #'ignore))))
