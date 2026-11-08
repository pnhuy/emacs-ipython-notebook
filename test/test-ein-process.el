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

;;; Open anywhere: no root to choose, no notebook list.

(defun ein:testing-process--table (&rest dirs)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (dir dirs table)
      (puthash dir (make-ein:$process :pid 1 :url (format "http://localhost:%d/" (length dir))
                                      :dir dir)
               table))))

(ert-deftest ein:process-dir-match-contains ()
  "A root matches files under it, not files that merely share its prefix;
the deepest root wins."
  (let ((ein:%processes% (ein:testing-process--table "/tmp" "/tmp/nb" "/tmp/nbroot")))
    (should (equal (ein:$process-dir (ein:process-dir-match "/tmp/nbroot/a.ipynb"))
                   "/tmp/nbroot"))
    (should (equal (ein:$process-dir (ein:process-dir-match "/tmp/nb2/a.ipynb"))
                   "/tmp"))
    (should-not (ein:process-dir-match "/home/a.ipynb")))
  (let ((ein:%processes% (ein:testing-process--table "/")))
    (should (equal (ein:$process-dir (ein:process-dir-match "/home/u/a.ipynb")) "/"))
    (should (equal (ein:process--root-path "/" "/home/u/a.ipynb") "home/u/a.ipynb"))))

(defmacro ein:testing-process--no-servers (&rest body)
  "Run BODY with no running server, no environments, and no prompts."
  (declare (indent 0))
  `(let ((ein:%processes% (make-hash-table :test #'equal))
         (ein:jupyter-use-containers nil)
         (ein:pyenv-auto-select nil)
         (ein:pyenv-data-directory (make-temp-file "ein-pyenv-" t)))
     (cl-letf (((symbol-function 'ein:process-refresh-processes) #'ignore)
               ((symbol-function 'read-directory-name)
                (lambda (&rest _) (error "Asked for a root directory"))))
       ,@body)))

(ert-deftest ein:process-open-starts-implicit-server ()
  "Without a server for the file, EIN starts one at the implicit root,
without asking for a directory, and opens the file's path on it."
  (ein:testing-process--no-servers
    (let ((ein:jupyter-implicit-root "/")
          started opened)
      (cl-letf (((symbol-function 'ein:jupyter-server-process) #'ignore)
                ((symbol-function 'ein:jupyter-server-start)
                 (lambda (_cmd dir _no-login callback _port args)
                   (setq started (list dir args))
                   (funcall callback nil 8888)))
                ((symbol-function 'ein:notebook-open)
                 (lambda (url path &rest _) (setq opened (list url path)))))
        (ein:process-open-notebook* "/tmp/somewhere/a.ipynb" #'ignore)
        (should (equal (car started) "/"))
        (should (member "--ContentsManager.allow_hidden=True" (cadr started)))
        (should (equal opened '(8888 "tmp/somewhere/a.ipynb")))))))

(ert-deftest ein:process-open-reuses-covering-server ()
  "A running server whose root contains the file is used as is."
  (ein:testing-process--no-servers
    (let (opened)
      (cl-letf (((symbol-function 'ein:process-refresh-processes)
                 (lambda () (setq ein:%processes% (ein:testing-process--table "/tmp/proj"))))
                ((symbol-function 'ein:notebooklist-list-get) (lambda (&rest _) t))
                ((symbol-function 'ein:jupyter-server-start)
                 (lambda (&rest _) (error "Started a server")))
                ((symbol-function 'ein:notebook-open)
                 (lambda (url path &rest _) (setq opened (list url path)))))
        (ein:process-open-notebook* "/tmp/proj/sub/a.ipynb" #'ignore)
        (should (equal (cadr opened) "sub/a.ipynb"))))))

(ert-deftest ein:process-open-outside-managed-server ()
  "EIN's own server does not cover the file: say so, start nothing."
  (ein:testing-process--no-servers
    (cl-letf (((symbol-function 'ein:jupyter-server-process) (lambda () 'proc))
              ((symbol-function 'ein:jupyter-running-notebook-directory)
               (lambda () "/tmp/other"))
              ((symbol-function 'ein:jupyter-server-start)
               (lambda (&rest _) (error "Started a server"))))
      (should-error (ein:process-open-notebook* "/tmp/proj/a.ipynb" #'ignore)
                    :type 'user-error))))

(ert-deftest ein:process-new-notebook-file ()
  "A missing or empty file becomes a notebook with one empty code cell;
a file with contents is never touched."
  (let* ((dir (make-temp-file "ein-new-" t))
         (new (expand-file-name "sub/new.ipynb" dir))
         (empty (expand-file-name "empty.ipynb" dir))
         (full (expand-file-name "full.ipynb" dir)))
    (unwind-protect
        (progn
          (write-region "" nil empty nil 'silent)
          (write-region "not json" nil full nil 'silent)
          (dolist (f (list new empty full))
            (ein:process--ensure-notebook-file f))
          (dolist (f (list new empty))
            (let ((nb (json-parse-string (with-temp-buffer
                                           (insert-file-contents f)
                                           (buffer-string)))))
              (should (= (gethash "nbformat" nb) 4))
              (let ((cells (gethash "cells" nb)))
                (should (= 1 (length cells)))
                (should (equal "code" (gethash "cell_type" (aref cells 0))))
                (should (equal "" (gethash "source" (aref cells 0))))
                (should (string-match-p "\\`[0-9a-f]\\{8\\}\\'"
                                        (gethash "id" (aref cells 0)))))))
          (should (equal (with-temp-buffer (insert-file-contents full) (buffer-string))
                         "not json")))
      (delete-directory dir t))))

(ert-deftest ein:process-open-remote-file-refused ()
  (should-error (ein:process-open-notebook "/ssh:host:/a.ipynb") :type 'user-error))

;; The implicit server is rooted at /; listing it would crawl /proc, /root...
(ert-deftest ein:process-implicit-server-not-crawled ()
  (let (queried result
        (ein:content-hierarchy-skip-functions
         (list (lambda (url) (equal url "http://127.0.0.1:8888")))))
    (cl-letf (((symbol-function 'ein:content-query-sessions)
               (lambda (&rest _) (setq queried t)))
              ((symbol-function 'ein:log-wrapper) #'ignore))
      (ein:content-query-hierarchy "http://127.0.0.1:8888"
                                   (lambda (tree) (setq result (list tree))))
      (should-not queried)
      (should (equal result '(nil)))
      (should-not (ein:content-need-hierarchy "http://127.0.0.1:8888"))
      (ein:content-query-hierarchy "http://127.0.0.1:9999")
      (should queried))))

(ert-deftest ein:process-implicit-server-url-p ()
  (let ((ein:jupyter-implicit-root "/")
        (dir "/"))
    (cl-letf (((symbol-function 'ein:jupyter-server-process) (lambda () 'proc))
              ((symbol-function 'process-get) (lambda (&rest _) nil))
              ((symbol-function 'process-put) #'ignore)
              ((symbol-function 'ein:jupyter-running-notebook-directory) (lambda () dir))
              ((symbol-function 'ein:jupyter-my-url-or-port)
               (lambda () "http://127.0.0.1:8888")))
      (should (ein:jupyter--implicit-server-url-p "http://127.0.0.1:8888"))
      (should (ein:jupyter--implicit-server-url-p 8888))
      (should-not (ein:jupyter--implicit-server-url-p "http://127.0.0.1:9999"))
      (setq dir "~/Downloads/")
      (should-not (ein:jupyter--implicit-server-url-p "http://127.0.0.1:8888")))))
