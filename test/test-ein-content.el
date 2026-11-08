;;; test-ein-content.el --- Testing content interface  -*- lexical-binding:t -*-

;; Copyright (C) 2015 John Miller

;; Authors: Takafumi Arakaki <aka.tkf at gmail.com>
;;          John M. Miller <millejoh at mac.com>

;; This file is NOT part of GNU Emacs.

;; test-ein-content.el is free software: you can redistribute it
;; and/or modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; test-ein-content.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-testing-notebook.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'ein-contents-api)

(defvar *list-content-result* nil)

(defun ein-test-list-contents-1 ()
  (ein:content-list-contents "" )
  )

;;; Safe, conflict-checked save (T059, T069, T070)

(require 'ein-testing-notebook)
(require 'ein-testing-nbformat)
(require 'ein-nbview)

(defvar eintest:save-requests nil
  "List of (TYPE URL SETTINGS) sent by `ein:query-singleton-ajax', newest first.")

(defmacro eintest:with-save-stub (server-last-modified &rest body)
  "Run BODY with HTTP stubbed.
GET returns SERVER-LAST-MODIFIED, fails with HTTP 500 when that is
`:fail', or without a response when it is `:unreachable'; PUT records
the request and does not call back (the test drives the callbacks)."
  (declare (indent 1))
  `(let ((eintest:save-requests nil))
     (cl-letf (((symbol-function 'ein:query-singleton-ajax)
                (lambda (url &rest settings)
                  (let ((type (plist-get settings :type)))
                    (push (list type url settings) eintest:save-requests)
                    (when (equal type "GET")
                      (pcase ,server-last-modified
                        (:fail (funcall (plist-get settings :error)
                                        :symbol-status 'error
                                        :response (make-request-response :status-code 500)))
                        (:unreachable (funcall (plist-get settings :error)
                                               :symbol-status 'error
                                               :response (make-request-response)))
                        (modified (funcall (plist-get settings :success)
                                           :data (list :last_modified modified)))))))))
       ,@body)))

(defun eintest:save-puts ()
  (cl-remove-if-not (lambda (r) (equal (car r) "PUT")) eintest:save-requests))

(defmacro eintest:with-dirty-notebook (&rest body)
  (declare (indent 0))
  `(ein:testing-with-notebook-file (ein:testing-fixture "smoke.ipynb")
     (setf (ein:$notebook-dirty ein:%notebook%) t)
     ,@body))

(ert-deftest ein:content-save-encode-failure ()
  "(a) Unencodable value: no PUT, still dirty, message mentions retry."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-metadata ein:%notebook%)
          (plist-put (copy-sequence (ein:$notebook-metadata ein:%notebook%))
                     :bad (current-buffer)))
    (eintest:with-save-stub nil
      (let ((err (should-error (ein:notebook-save-notebook ein:%notebook%)
                               :type 'user-error)))
        (should (string-match-p "Save aborted.*retry" (cadr err))))
      (should-not eintest:save-requests))
    (should (ein:notebook-modified-p ein:%notebook%))))

(ert-deftest ein:content-save-utf8-body ()
  "(b) The PUT body is UTF-8 bytes whatever the buffer coding system."
  (eintest:with-dirty-notebook
    (let ((cell (cl-find-if (lambda (c) (cl-typep c 'ein:codecell))
                            (ein:worksheet-get-cells ein:%worksheet%))))
      (ein:cell-set-text cell "s = \"→\""))
    (setq-local buffer-file-coding-system 'latin-1)
    (eintest:with-save-stub nil
      (ein:notebook-save-notebook ein:%notebook%)
      (let ((body (plist-get (nth 2 (car (eintest:save-puts))) :data)))
        (should (stringp body))
        (should-not (multibyte-string-p body))
        (should (string-match-p "s = \\\\\"→\\\\\"" (decode-coding-string body 'utf-8)))))))

(ert-deftest ein:content-save-conflict-cancel ()
  "(c) Changed last_modified: prompt; cancel means no PUT, still dirty."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "2026-01-01T00:00:00Z")
    (let (asked)
      (cl-letf (((symbol-function 'ein:notebook--confirm-overwrite)
                 (lambda (_nb) (setq asked t) 'cancel)))
        (eintest:with-save-stub "2026-02-02T00:00:00Z"
          (ein:notebook-save-notebook ein:%notebook%)
          (should asked)
          (should (= 1 (length eintest:save-requests)))
          (should-not (eintest:save-puts)))))
    (should (ein:notebook-modified-p ein:%notebook%))))

(ert-deftest ein:content-save-conflict-overwrite ()
  "(c') Overwrite proceeds with the PUT; same last_modified does not ask."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
    (cl-letf (((symbol-function 'ein:notebook--confirm-overwrite)
               (lambda (_nb) 'overwrite)))
      (eintest:with-save-stub "t2"
        (ein:notebook-save-notebook ein:%notebook%)
        (should (= 1 (length (eintest:save-puts))))
        (eintest:save-succeed (car (eintest:save-puts)) "t1")))
    (cl-letf (((symbol-function 'ein:notebook--confirm-overwrite)
               (lambda (_nb) (error "Should not ask"))))
      (eintest:with-save-stub "t1"
        (ein:notebook-save-notebook ein:%notebook%)
        (should (= 1 (length (eintest:save-puts))))))))

(ert-deftest ein:content-save-dirty-cleared-only-on-success ()
  "(d) Dirty stays until the success callback; an error keeps it."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
    (eintest:with-save-stub "t1"
      ;; Error path.
      (ein:notebook-save-notebook ein:%notebook%)
      (should (ein:notebook-modified-p ein:%notebook%))
      (let ((settings (nth 2 (car (eintest:save-puts)))) msg)
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
          (funcall (plist-get settings :error) :symbol-status 'error))
        (should (string-match-p "Save failed (error); notebook still modified — retry with C-x C-s"
                                msg)))
      (should (ein:notebook-modified-p ein:%notebook%))
      ;; Success path.
      (setq eintest:save-requests nil)
      (ein:notebook-save-notebook ein:%notebook%)
      (should (ein:notebook-modified-p ein:%notebook%))
      (funcall (plist-get (nth 2 (car (eintest:save-puts))) :success)
               :data (list :last_modified "t3"))
      (should-not (ein:notebook-modified-p ein:%notebook%))
      (should (equal "t3" (ein:$notebook-last-modified ein:%notebook%))))))

(defun eintest:save-edit-a-cell (text)
  (let ((cell (cl-find-if (lambda (c) (cl-typep c 'ein:codecell))
                          (ein:worksheet-get-cells ein:%worksheet%))))
    (ein:cell-set-text cell text)))

(defun eintest:save-succeed (request last-modified)
  (funcall (plist-get (nth 2 request) :success)
           :data (list :last_modified last-modified)))

(defun eintest:save-body (request)
  (decode-coding-string (plist-get (nth 2 request) :data) 'utf-8))

(ert-deftest ein:content-save-keeps-edits-made-while-saving ()
  "An edit typed while the save is in flight stays modified after it succeeds."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
    (eintest:with-save-stub "t1"
      (eintest:save-edit-a-cell "before_save")
      (ein:notebook-save-notebook ein:%notebook%)
      (let ((put (car (eintest:save-puts))))
        (should (string-match-p "before_save" (eintest:save-body put)))
        (eintest:save-edit-a-cell "after_save")
        (eintest:save-succeed put "t2"))
      (should (ein:notebook-modified-p ein:%notebook%))
      ;; Saving again sends the edit and then clears modified.
      (setq eintest:save-requests nil)
      (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
      (ein:notebook-save-notebook ein:%notebook%)
      (eintest:save-succeed (car (eintest:save-puts)) "t3")
      (should-not (ein:notebook-modified-p ein:%notebook%)))))

(ert-deftest ein:content-save-keeps-execution-results-made-while-saving ()
  "Output and a count arriving while the save is in flight stay modified.
In the cell view they change no buffer text, yet the server lacks them."
  (let ((ein:notebook-view 'cells))
    (eintest:with-dirty-notebook
      (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
      (eintest:with-save-stub "t1"
        (let ((cell (cl-find-if #'ein:codecell-p (ein:view-cells ein:nbview--view))))
          (ein:notebook-save-notebook ein:%notebook%)
          (let ((put (car (eintest:save-puts)))
                (tick (buffer-chars-modified-tick)))
            (ein:cell--handle-output cell "stream" '(:name "stdout" :text "late\n") nil)
            (ein:cell--handle-execute-reply cell '(:execution_count 99 :status "ok") nil)
            (should (= tick (buffer-chars-modified-tick)))
            (should (ein:notebook-modified-p ein:%notebook%))
            (eintest:save-succeed put "t2"))
          (should (ein:notebook-modified-p ein:%notebook%))
          ;; Saving again sends them and then clears modified.
          (setq eintest:save-requests nil)
          (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
          (ein:notebook-save-notebook ein:%notebook%)
          (let ((put (car (eintest:save-puts))))
            (should (string-match-p "\"execution_count\": *99" (eintest:save-body put)))
            (should (string-match-p "late" (eintest:save-body put)))
            (eintest:save-succeed put "t3"))
          (should-not (ein:notebook-modified-p ein:%notebook%)))))))

;; In the cell view, outputs change no buffer text, so they must mark
;; the notebook modified themselves.

(defun eintest:clean-cells-notebook-code-cell ()
  "Mark the current notebook saved; return its first code cell."
  (ein:notebook-save-notebook-success ein:%notebook%)
  (should-not (ein:notebook-modified-p ein:%notebook%))
  (cl-find-if #'ein:codecell-p (ein:view-cells ein:nbview--view)))

(ert-deftest ein:content-output-marks-clean-notebook-modified ()
  "Output arriving after its execute reply (a background thread) is unsaved."
  (let ((ein:notebook-view 'cells))
    (eintest:with-dirty-notebook
      (let ((cell (eintest:clean-cells-notebook-code-cell)))
        (ein:cell--handle-output cell "stream" '(:name "stdout" :text "bg\n") nil)
        (should (ein:notebook-modified-p ein:%notebook%))
        (ein:notebook-save-notebook-success ein:%notebook%)
        (ein:cell--handle-output cell "display_data"
                                 '(:data (:text/plain "a") :metadata nil
                                         :transient (:display_id "d1"))
                                 nil)
        (ein:notebook-save-notebook-success ein:%notebook%)
        (ein:cell--handle-output cell "update_display_data"
                                 '(:data (:text/plain "b") :metadata nil
                                         :transient (:display_id "d1"))
                                 nil)
        (should (ein:notebook-modified-p ein:%notebook%))
        (ein:notebook-save-notebook-success ein:%notebook%)
        (ein:cell-clear-output cell t t t)
        (should (ein:notebook-modified-p ein:%notebook%))))))

(ert-deftest ein:content-save-of-clean-notebook-keeps-later-output ()
  "A save that does not hold the latest output leaves the notebook modified,
even when nothing else had marked it so."
  (let ((ein:notebook-view 'cells))
    (eintest:with-dirty-notebook
      (let ((cell (eintest:clean-cells-notebook-code-cell)))
        (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
        (eintest:with-save-stub "t1"
          (ein:notebook-save-notebook ein:%notebook%)
          (let ((put (car (eintest:save-puts))))
            ;; A change the save lacks that no hook reports.
            (setf (slot-value cell 'outputs)
                  (list '(:output_type "stream" :name "stdout" :text "unseen\n")))
            (eintest:save-succeed put "t2")))
        (should (ein:notebook-modified-p ein:%notebook%))))))

(ert-deftest ein:content-save-serializes-overlapping-saves ()
  "A save asked for during another waits for it, keeping its callback."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
    (eintest:with-save-stub "t1"
      (cl-letf (((symbol-function 'message) #'ignore))
        (let (called)
          (ein:notebook-save-notebook ein:%notebook%)
          (eintest:save-edit-a-cell "second")
          (ein:notebook-save-notebook ein:%notebook% (lambda (x) (setq called x)) '(done))
          (should (= 1 (length (eintest:save-puts))))
          ;; The first succeeds; the queued save starts with the newer text.
          (eintest:save-succeed (car (eintest:save-puts)) "t1")
          (should (= 2 (length (eintest:save-puts))))
          (should (string-match-p "second" (eintest:save-body (car (eintest:save-puts)))))
          (should-not called)
          (eintest:save-succeed (car (eintest:save-puts)) "t1")
          (should (eq called 'done))
          (should-not (ein:$notebook-saving ein:%notebook%))
          (should-not (ein:notebook-modified-p ein:%notebook%)))))))

(ert-deftest ein:content-save-unverified-conflict-asks ()
  "When the server copy cannot be checked, ask; declining sends no PUT."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
    (cl-letf (((symbol-function 'message) #'ignore))
      (let (asked)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_p) (setq asked t) nil)))
          (eintest:with-save-stub :fail
            (ein:notebook-save-notebook ein:%notebook%)
            (should asked)
            (should-not (eintest:save-puts))))
        (should (ein:notebook-modified-p ein:%notebook%))
        (should-not (ein:$notebook-saving ein:%notebook%))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_p) t)))
          (eintest:with-save-stub :fail
            (ein:notebook-save-notebook ein:%notebook%)
            (should (= 1 (length (eintest:save-puts))))))))))

(ert-deftest ein:content-save-unreachable-server-fails ()
  "When the server cannot be reached, the save fails without asking:
the PUT could not reach it either."
  (eintest:with-dirty-notebook
    (setf (ein:$notebook-last-modified ein:%notebook%) "t1")
    (let (messages failed)
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages)))
                ((symbol-function 'yes-or-no-p) (lambda (_p) (ert-fail "Asked"))))
        (eintest:with-save-stub :unreachable
          (ein:notebook-save-notebook ein:%notebook% nil nil (lambda () (setq failed t)))
          (should-not (eintest:save-puts))))
      (should failed)
      (should (cl-some (lambda (m) (string-match-p "retry with C-x C-s" m)) messages))
      (should (ein:notebook-modified-p ein:%notebook%))
      (should-not (ein:$notebook-saving ein:%notebook%)))))

;;; Save copy

(defmacro eintest:with-copy-stub (exists &rest body)
  "Run BODY with HTTP stubbed: GET answers EXISTS (t, nil for 404, or
`:error'), PUT is recorded."
  (declare (indent 1))
  `(let ((eintest:save-requests nil))
     (cl-letf (((symbol-function 'ein:query-singleton-ajax)
                (lambda (url &rest settings)
                  (let ((type (plist-get settings :type)))
                    (push (list type url settings) eintest:save-requests)
                    (when (equal type "GET")
                      (pcase ,exists
                        ('t (funcall (plist-get settings :success) :data nil))
                        ('nil (funcall (plist-get settings :error)
                                       :response (make-request-response :status-code 404)))
                        (_ (funcall (plist-get settings :error)
                                    :response (make-request-response :status-code 500)))))))))
       ,@body)))

(ert-deftest ein:content-save-copy-asks-before-replacing ()
  "Copying onto an existing notebook asks; declining sends no PUT."
  (eintest:with-dirty-notebook
    (dolist (exists '(t :error))
      (let (asked)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_p) (setq asked t) nil)))
          (eintest:with-copy-stub exists
            (ein:notebook-save-to-command "other.ipynb")
            (should asked)
            (should-not (eintest:save-puts))))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_p) t))
              ((symbol-function 'ein:notebook-open) #'ignore))
      (eintest:with-copy-stub t
        (ein:notebook-save-to-command "other")
        (should (string-suffix-p "other.ipynb" (nth 1 (car (eintest:save-puts)))))))))

(ert-deftest ein:content-save-copy-to-new-path ()
  "A new path is saved without asking; this notebook's own path is refused."
  (eintest:with-dirty-notebook
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_p) (error "Should not ask")))
              ((symbol-function 'ein:notebook-open) #'ignore))
      (eintest:with-copy-stub nil
        (ein:notebook-save-to-command "dir/new.ipynb")
        (let ((content (ein:json-read-from-string
                        (eintest:save-body (car (eintest:save-puts))))))
          (should (equal "dir/new.ipynb" (plist-get content :path)))
          (should (equal "new.ipynb" (plist-get content :name)))))
      (should-error (ein:notebook-save-to-command
                     (ein:$notebook-notebook-path ein:%notebook%))
                    :type 'user-error))
    (should (equal "a/b-Copy.ipynb" (ein:notebook--copy-path "a/b.ipynb")))))
