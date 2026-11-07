;;; test-ein-reconnect.el --- Disconnect, reconnect, kernel death -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-reconnect.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-reconnect.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-reconnect.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T034: a dropped websocket leaves the buffer editable and can be
;; reconnected; a kernel killed mid-output keeps the partial output,
;; reports dead or disconnected and signals no error.

;;; Code:

(require 'ein-testing-live)
(require 'ein-notebook)
(require 'ein-notebooklist)

(defun ein:testing--buffer-editable-p (notebook)
  "Insert and remove a character in NOTEBOOK's first cell input."
  (with-current-buffer (ein:notebook-buffer notebook)
    (let ((cell (or (ein:worksheet-get-current-cell :noerror t)
                    (ein:worksheet-insert-cell-below
                     (ein:worksheet--get-ws-or-error) 'code nil t))))
      (ein:cell-goto cell)
      (insert "z")
      (delete-char -1)
      t)))

(ert-deftest ein:integration-reconnect-and-kernel-death ()
  :tags '(:integration)
  (ein:testing-with-server (url token)
    (let ((ein:jupyter-server-use-subcommand "server")
          notebook)
      (ein:testing-empty-notebook "reconnect.ipynb")
      (unwind-protect
          (let* ((_ (setq notebook (ein:testing-login-and-open url token "reconnect.ipynb")))
                 (kernel (ein:$notebook-kernel notebook)))
            (should (ein:testing-wait-until (lambda () (ein:kernel-live-p kernel)) 30))
            ;; Drop the websocket from under EIN.
            (websocket-close (ein:$websocket-ws (ein:$kernel-websocket kernel)))
            (should (ein:testing-wait-until
                     (lambda () (eq (ein:$kernel-status kernel) 'disconnected)) 10))
            (should (ein:testing--buffer-editable-p notebook))
            ;; Reconnect from the notebook buffer.
            (with-current-buffer (ein:notebook-buffer notebook)
              (ein:notebook-reconnect-session-command))
            (should (ein:testing-wait-until (lambda () (ein:kernel-live-p kernel)) 30))
            (should (equal (ein:testing-result-text (ein:testing-execute kernel "1")) "1"))
            ;; Kill the kernel process while it streams output.
            (let (pid streamed errors statuses)
              (advice-add 'ein:kernel--set-status :after
                          (lambda (_k status) (push status statuses))
                          '((name . ein:testing-status-log)))
              (ein:kernel-execute
               kernel
               "import os, time\nprint('pid', os.getpid(), flush=True)\nfor i in range(100):\n    print(i, flush=True)\n    time.sleep(0.1)"
               (list :output
                     (cons (lambda (_ msg-type content _m)
                             (condition-case err
                                 (when (equal msg-type "stream")
                                   (let ((text (plist-get content :text)))
                                     (push text streamed)
                                     (when (and (not pid)
                                                (string-match "pid \\([0-9]+\\)" text))
                                       (setq pid (string-to-number (match-string 1 text))))))
                               (error (push err errors))))
                           nil))
               :silent nil)
              (should (ein:testing-wait-until (lambda () (>= (length streamed) 3)) 15))
              (should pid)
              (signal-process pid 'SIGKILL)
              (unwind-protect
                  (should (ein:testing-wait-until
                           (lambda () (or (memq 'dead statuses)
                                          (memq 'disconnected statuses)))
                           20))
                (advice-remove 'ein:kernel--set-status 'ein:testing-status-log))
              (should streamed)        ; partial output kept
              (should-not errors)
              (should (ein:testing--buffer-editable-p notebook))))
        (ein:testing-kill-notebook notebook)))))

(provide 'test-ein-reconnect)
;;; test-ein-reconnect.el ends here
