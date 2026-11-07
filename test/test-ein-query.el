;;; test-ein-query.el --- Retry scheduling in ein-query  -*- lexical-binding:t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-query.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-query.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-query.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T053: HTTP retries from request callbacks must not block Emacs with
;; `sleep-for'; they are rescheduled on a timer unless `ein:force-sync'.

;;; Code:

(require 'ert)
(require 'ein-query)
(require 'ein-contents-api)
(require 'ein-kernel)
(require 'ein-notebooklist)

(defmacro ein:testing-no-sleep (&rest body)
  "Run BODY failing on `sleep-for'; return the timers BODY scheduled."
  (declare (indent 0))
  `(let (scheduled)
     (cl-letf (((symbol-function 'sleep-for)
                (lambda (&rest _) (error "sleep-for on a callback path")))
               ((symbol-function 'run-at-time)
                (lambda (delay _repeat fn &rest args)
                  (push (list delay fn args) scheduled)
                  'fake-timer)))
       ,@body)
     scheduled))

(ert-deftest ein:query-retry-later--async-uses-timer ()
  (let* ((ein:force-sync nil)
         called
         (timers (ein:testing-no-sleep
                   (ein:query--retry-later 0.5 (lambda (x) (setq called x)) 1))))
    (should-not called)
    (should (equal (car (car timers)) 0.5))
    (apply (nth 1 (car timers)) (nth 2 (car timers)))
    (should (equal called 1))))

(ert-deftest ein:query-retry-later--sync-calls-now ()
  (let ((ein:force-sync t) called)
    (cl-letf (((symbol-function 'sleep-for) #'ignore))
      (ein:query--retry-later 0.5 (lambda () (setq called t))))
    (should called)))

(ert-deftest ein:content-query-contents--error-retries-without-sleep ()
  (let* ((ein:force-sync nil)
         (resp (make-request-response :status-code 500))
         (timers (ein:testing-no-sleep
                   (ein:content-query-contents--error
                    "http://127.0.0.1:8888" "" #'ignore #'ignore 0
                    :response resp))))
    (should (= 1 (length timers)))))

(ert-deftest ein:content-query-sessions--error-retries-without-sleep ()
  (let* ((ein:force-sync nil)
         (resp (make-request-response :status-code 500))
         (timers (ein:testing-no-sleep
                   (ein:content-query-sessions--error
                    "http://127.0.0.1:8888" #'ignore #'ignore 0
                    :response resp))))
    (should (= 1 (length timers)))))

(ert-deftest ein:kernel-retrieve-session--error-retries-without-sleep ()
  (let* ((ein:force-sync nil)
         (timers (ein:testing-no-sleep
                   (ein:kernel-retrieve-session--error
                    'kernel 0 #'ignore :error-thrown '(error . "x")))))
    (should (= 1 (length timers))))
  ;; Out of tries: no retry, still no sleep.
  (should-not (ein:testing-no-sleep
                (ein:kernel-retrieve-session--error
                 'kernel 2 #'ignore :error-thrown '(error . "x")))))

(ert-deftest ein:notebooklist-new-notebook-error-retries-without-sleep ()
  (let* ((ein:force-sync nil)
         (timers (ein:testing-no-sleep
                   (ein:notebooklist-new-notebook-error
                    "http://127.0.0.1:8888" nil #'ignore t nil nil
                    :symbol-status 'error :error-thrown '(error . "x")))))
    (should (= 1 (length timers)))))

(provide 'test-ein-query)
;;; test-ein-query.el ends here
