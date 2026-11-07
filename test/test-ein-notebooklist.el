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

(ert-deftest ein:notebooklist-login--canonical-key ()
  "A trailing slash does not create a second server key."
  (let (seen)
    (cl-letf (((symbol-function 'ein:notebooklist-token-or-password) (lambda (_) ""))
              ((symbol-function 'ein:notebooklist-open*)
               (lambda (url &rest _) (setq seen url))))
      (ein:notebooklist-login "http://127.0.0.1:8888/" #'ignore)
      (should (equal seen "http://127.0.0.1:8888")))))
