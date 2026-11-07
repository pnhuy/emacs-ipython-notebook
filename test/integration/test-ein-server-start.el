;;; test-ein-server-start.el --- ein:run against modern jupyter -*- lexical-binding: t -*-

;; Copyright (C) 2026 Huy Pham

;; This file is NOT part of GNU Emacs.

;; test-ein-server-start.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; test-ein-server-start.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with test-ein-server-start.el.
;; If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; T032: with subcommand auto-detection, `ein:jupyter-server-start'
;; starts a server, logs in through its callback within 30 s, keeps
;; timers running while it waits, and `ein:jupyter-server-stop' ends it.

;;; Code:

(require 'ein-testing-live)
(require 'ein-jupyter)
(require 'ein-notebooklist)

(ert-deftest ein:integration-server-start-stop ()
  :tags '(:integration)
  (unless (executable-find "jupyter")
    (ert-skip "jupyter not in PATH"))
  (let* ((ein:jupyter-server-use-subcommand nil)
         (ein:jupyter--detected-subcommand nil)
         (dir (make-temp-file "ein-start-" t))
         (port (ein:testing-server--free-port))
         (ticks 0)
         (timer (run-at-time 0.05 0.05 (lambda () (cl-incf ticks))))
         logged-in proc)
    (unwind-protect
        (progn
          (ein:jupyter-server-start (executable-find "jupyter") dir nil
                                    (lambda (_buffer url-or-port)
                                      (setq logged-in url-or-port))
                                    port)
          (setq proc (ein:jupyter-server-process))
          (should (equal ein:jupyter--detected-subcommand "server"))
          (should (process-live-p proc))
          (should (ein:jupyter-server-ready-p))
          (should (> ticks 0))          ; timers ran during startup
          (should (ein:testing-wait-until (lambda () logged-in) 30))
          (should (string-match-p (format ":%d" port) logged-in))
          (ein:jupyter-server-stop nil logged-in)
          (should (ein:testing-wait-until (lambda () (not (process-live-p proc))) 15)))
      (cancel-timer timer)
      (when (process-live-p proc) (delete-process proc))
      (when-let* ((buf (get-buffer *ein:jupyter-server-buffer-name*)))
        (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))
      (delete-directory dir t))))

(provide 'test-ein-server-start)
;;; test-ein-server-start.el ends here
