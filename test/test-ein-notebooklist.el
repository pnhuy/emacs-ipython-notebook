;; -*- lexical-binding:t -*-
(require 'ein-notebooklist)
(require 'ein-testing-notebook)

(defun eintest:notebooklist-make-empty (&optional url-or-port)
  "Make empty notebook list buffer."
  (let ((url-or-port (or url-or-port ein:testing-notebook-dummy-url)))
    (cl-letf (((symbol-function 'ein:need-kernelspecs) #'ignore)
              ((symbol-function 'ein:content-query-sessions) #'ignore))
      (ein:notebooklist-open--finish url-or-port #'ignore
        (make-ein:$content :url-or-port url-or-port
                           :notebook-api-version "5"
                           :path "")))))

(defmacro eintest:notebooklist-is-empty-context-of (func)
  `(ert-deftest ,(intern (format "%s--notebooklist" func)) ()
     (with-current-buffer (eintest:notebooklist-make-empty)
       (should-not (,func)))))

(ert-deftest ein:get-url-or-port--notebooklist ()
  (with-current-buffer (eintest:notebooklist-make-empty)
    (should (equal (ein:get-url-or-port) ein:testing-notebook-dummy-url))))

(eintest:notebooklist-is-empty-context-of ein:get-notebook)
(eintest:notebooklist-is-empty-context-of ein:get-kernel)
(eintest:notebooklist-is-empty-context-of ein:get-cell-at-point)
(eintest:notebooklist-is-empty-context-of ein:get-traceback-data)

(ert-deftest ein:notebooklist-token-or-password--empty-token-is-unknown ()
  "jupyter_server 2.x lists password servers as password false, token \"\"."
  (cl-letf (((symbol-function 'ein:jupyter-crib-token)
             (lambda (_) (list :json-false ""))))
    (should-not (ein:notebooklist-token-or-password "http://127.0.0.1:8888")))
  (cl-letf (((symbol-function 'ein:jupyter-crib-token)
             (lambda (_) (list :json-false "abc"))))
    (should (equal (ein:notebooklist-token-or-password "http://127.0.0.1:8888")
                   "abc"))))

(defun ein:testing--cookie-line (domain name)
  (mapconcat #'identity
             (list domain "FALSE" "/" "FALSE" "1999999999" name "v")
             "\t"))

(defmacro ein:testing--with-cookie-jar (lines &rest body)
  "Run BODY with a private curl cookie jar holding LINES."
  (declare (indent 1))
  `(let* ((request-storage-directory (make-temp-file "ein-jar-" t))
          (request--curl-cookie-jar nil))
     (unwind-protect
         (progn
           (with-temp-file (request--curl-cookie-jar)
             (insert "# Netscape HTTP Cookie File\n\n"
                     (mapconcat #'identity ,lines "\n") "\n"))
           ,@body)
       (delete-directory request-storage-directory t))))

(defun ein:testing--jar-names ()
  (with-temp-buffer
    (insert-file-contents (request--curl-cookie-jar))
    (mapcar (lambda (c) (nth 6 c)) (request--netscape-cookie-parse))))

(ert-deftest ein:notebooklist-login--prune-cookies-drops-dead-local-servers ()
  "Login cookies of local servers no longer running are dropped (403 fix)."
  (ein:testing--with-cookie-jar
      (list (ein:testing--cookie-line "#HttpOnly_127.0.0.1" "username-127-0-0-1-1111")
            (ein:testing--cookie-line "#HttpOnly_127.0.0.1" "username-127-0-0-1-2222")
            (ein:testing--cookie-line "#HttpOnly_127.0.0.1" "username-127-0-0-1-8888")
            (ein:testing--cookie-line "127.0.0.1" "_xsrf")
            (ein:testing--cookie-line "#HttpOnly_example.org" "username-example-org-1111"))
    (cl-letf (((symbol-function 'ein:jupyter-crib-running-servers)
               (lambda () (list (list :port 2222 :url "http://localhost:2222/")))))
      (ein:notebooklist-login--prune-cookies "http://127.0.0.1:8888"))
    (should (equal (ein:testing--jar-names)
                   '("username-127-0-0-1-2222" "username-127-0-0-1-8888"
                     "_xsrf" "username-example-org-1111")))))

(ert-deftest ein:notebooklist-login--prune-cookies-leaves-remote-hosts ()
  "Remote hosts are never pruned: their servers cannot be listed."
  (ein:testing--with-cookie-jar
      (list (ein:testing--cookie-line "#HttpOnly_example.org" "username-example-org-1111"))
    (cl-letf (((symbol-function 'ein:jupyter-crib-running-servers)
               (lambda () (error "Must not be called"))))
      (ein:notebooklist-login--prune-cookies "http://example.org:8888"))
    (should (equal (ein:testing--jar-names) '("username-example-org-1111")))))

(ert-deftest ein:notebooklist-login--canonical-key ()
  "A trailing slash does not create a second server key."
  (let (seen)
    (cl-letf (((symbol-function 'ein:notebooklist-token-or-password) (lambda (_) ""))
              ((symbol-function 'ein:notebooklist-open*)
               (lambda (url &rest _) (setq seen url))))
      (ein:notebooklist-login "http://127.0.0.1:8888/" #'ignore)
      (should (equal seen "http://127.0.0.1:8888")))))
