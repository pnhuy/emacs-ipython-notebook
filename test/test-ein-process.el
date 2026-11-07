;; -*- lexical-binding:t -*-
(require 'ert)
(require 'ein-process)

(ert-deftest ein:process-check-suitable ()
  (should-not (equal (ein:process-suitable-notebook-dir (concat default-directory "features/support")) (concat default-directory "features/support"))))

(ert-deftest ein:process-divine ()
  (with-current-buffer "*scratch*"
    (erase-buffer))
  (ein:process-divine-dir 1 "" "*scratch*")
  (ein:process-divine-port 1 "" "*scratch*"))

;; T027: jupyter_server 2.x `list --json' emits root_dir, not notebook_dir.
(defun ein:testing-process--lines (&rest jsons)
  (lambda (&rest _) jsons))

(ert-deftest ein:process-refresh-root-dir ()
  (let ((ein:%processes% (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'process-lines)
               (ein:testing-process--lines
                "{\"base_url\": \"/\", \"hostname\": \"localhost\", \"password\": false, \"pid\": 4242, \"port\": 8888, \"root_dir\": \"/tmp/nbroot/\", \"secure\": false, \"sock\": \"\", \"token\": \"t0k\", \"url\": \"http://localhost:8888/\", \"version\": \"2.21.1\"}")))
      (ein:process-refresh-processes)
      (let ((proc (gethash "/tmp/nbroot" ein:%processes%)))
        (should proc)
        (should (equal (ein:$process-dir proc) "/tmp/nbroot"))
        (should (equal (ein:$process-pid proc) 4242))))))

(ert-deftest ein:process-refresh-notebook-dir-legacy ()
  (let ((ein:%processes% (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'process-lines)
               (ein:testing-process--lines
                "{\"pid\": 7, \"url\": \"http://localhost:8889/\", \"notebook_dir\": \"/tmp/legacy\"}"
                "{\"pid\": 8, \"url\": \"http://localhost:8890/\"}")))
      (ein:process-refresh-processes)
      (should (gethash "/tmp/legacy" ein:%processes%))
      ;; The entry with neither key is skipped, not an error.
      (should (= (hash-table-count ein:%processes%) 1)))))
