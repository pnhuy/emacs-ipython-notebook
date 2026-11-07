;;; test-ein-save-conflict.el --- Live conflict-checked save -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-save-conflict.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-save-conflict.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-save-conflict.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T060 (FR-012, G10): against a private jupyter server,
;;  - an external change is detected at save; cancel keeps the disk file,
;;    overwrite replaces it with a valid notebook;
;;  - saving while a cell runs writes a consistent notebook;
;;  - losing the server during save keeps the buffer modified, tells the
;;    user to retry, and leaves the disk file untouched.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ein-testing-server)
(require 'ein-testing-nbformat)
(require 'test-ein-smoke)

(defun ein:testing-save-and-wait (notebook &optional seconds)
  "Save NOTEBOOK and wait for the success callback; return non-nil on success."
  (let (saved)
    (ein:notebook-save-notebook notebook (lambda (&rest _) (setq saved t)))
    (ein:testing-wait-until (lambda () saved) (or seconds 20))))

(defun ein:testing-read-notebook (file)
  (json-parse-string (ein:testing-file-string file)
                     :object-type 'alist :array-type 'list
                     :null-object :null :false-object :false))

(defun ein:testing-cell-of-type (notebook type)
  (with-current-buffer (ein:notebook-buffer notebook)
    (cl-find-if (lambda (c) (cl-typep c type))
                (ein:worksheet-get-cells ein:%worksheet%))))

(defun ein:testing-saved-cell (file type)
  (cl-find type (alist-get 'cells (ein:testing-read-notebook file))
           :key (lambda (c) (alist-get 'cell_type c)) :test #'equal))

(defun ein:testing-set-text (notebook cell text)
  "Replace CELL's source with TEXT (`ein:cell-set-text' edits the current buffer)."
  (with-current-buffer (ein:notebook-buffer notebook)
    (ein:cell-set-text cell text)))

(defun ein:testing-joined (value)
  (if (listp value) (apply #'concat value) value))

(ert-deftest ein:integration-save-conflict ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let* ((ein:jupyter-server-use-subcommand "server")
           (file (expand-file-name "smoke.ipynb" ein:testing-server-dir))
           (server (get-buffer-process ein:testing-server-last-buffer))
           notebook)
      (copy-file (ein:testing-fixture "smoke.ipynb") file)
      (unwind-protect
          (progn
            (setq notebook (ein:testing-login-and-open
                            (directory-file-name url) token "smoke.ipynb"))
            (should (ein:testing-wait-until
                     (lambda () (ein:kernel-live-p (ein:$notebook-kernel notebook)))
                     30))
            (let ((code (ein:testing-cell-of-type notebook 'ein:codecell))
                  (markdown-source (alist-get 'source (ein:testing-saved-cell file "markdown"))))
              ;; 1. Edit a cell.
              (ein:testing-set-text notebook code "x = 41")
              (should (ein:notebook-modified-p notebook))
              ;; 2. Change the file behind EIN's back.
              (with-temp-buffer
                (should (zerop (call-process
                                "python3" nil t nil "-I" "-c"
                                "import nbformat, sys
nb = nbformat.read(sys.argv[1], as_version=4)
nb.cells.append(nbformat.v4.new_markdown_cell('external'))
nbformat.write(nb, sys.argv[1])"
                                file))))
              ;; 3. Cancel: nothing written, still modified.
              (let (asked)
                (cl-letf (((symbol-function 'ein:notebook--confirm-overwrite)
                           (lambda (_nb) (setq asked t) 'cancel)))
                  (ein:notebook-save-notebook notebook)
                  (should (ein:testing-wait-until (lambda () asked) 20))
                  (accept-process-output nil 0.5)))
              (should (string-match-p "external" (ein:testing-file-string file)))
              (should (ein:notebook-modified-p notebook))
              ;; 4. Overwrite: EIN's content is saved and valid.
              (cl-letf (((symbol-function 'ein:notebook--confirm-overwrite)
                         (lambda (_nb) 'overwrite)))
                (should (ein:testing-save-and-wait notebook)))
              (should-not (string-match-p "external" (ein:testing-file-string file)))
              (should (equal "x = 41" (ein:testing-joined
                                       (alist-get 'source (ein:testing-saved-cell file "code")))))
              (should-not (ein:notebook-modified-p notebook))
              (ein:testing-nbformat-validate file)
              ;; 5. Save while executing (FR-012).
              (ein:testing-set-text notebook code "import time; time.sleep(5); print(\"done\")")
              (with-current-buffer (ein:notebook-buffer notebook)
                (ein:cell-execute code))
              (should (ein:testing-wait-until (lambda () (oref code running)) 10))
              (cl-letf (((symbol-function 'ein:notebook--confirm-overwrite)
                         (lambda (_nb) (error "Unexpected conflict"))))
                (should (ein:testing-save-and-wait notebook))
                (should (oref code running))
                (ein:testing-nbformat-validate file)
                (let ((saved (ein:testing-saved-cell file "code")))
                  (should (eq :null (alist-get 'execution_count saved)))
                  (should (string-match-p "time.sleep"
                                          (ein:testing-joined (alist-get 'source saved)))))
                (should (equal markdown-source
                               (alist-get 'source (ein:testing-saved-cell file "markdown"))))
                (should (ein:testing-wait-until (lambda () (not (oref code running))) 30))
                (should (ein:testing-save-and-wait notebook))
                (let ((saved (ein:testing-saved-cell file "code")))
                  (should (integerp (alist-get 'execution_count saved)))
                  (should (string-match-p "done" (format "%S" (alist-get 'outputs saved))))))
              ;; 6. Server lost during save.
              (let ((bytes (ein:testing-file-string file))
                    (messages '())
                    (escaped nil))
                (ein:testing-set-text notebook code "y = 2")
                (signal-process server 'SIGTERM)
                (should (ein:testing-wait-until (lambda () (not (process-live-p server))) 15))
                (let ((orig-message (symbol-function 'message)))
                  (cl-letf (((symbol-function 'message)
                             (lambda (fmt &rest args)
                               (when fmt (push (apply #'format fmt args) messages))
                               (apply orig-message fmt args))))
                    (condition-case err
                        (ein:notebook-save-notebook notebook)
                      (error (setq escaped err)))
                    (should (ein:testing-wait-until
                             (lambda ()
                               (cl-some (lambda (m) (string-match-p "retry with C-x C-s" m))
                                        messages))
                             30))))
                (should-not escaped)
                (should (ein:notebook-modified-p notebook))
                (with-current-buffer (ein:notebook-buffer notebook)
                  (should (buffer-modified-p)))
                (should (equal bytes (ein:testing-file-string file))))))
        (ein:testing-kill-notebook notebook)))))

(provide 'test-ein-save-conflict)
;;; test-ein-save-conflict.el ends here
