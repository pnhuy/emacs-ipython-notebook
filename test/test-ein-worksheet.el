;; -*- lexical-binding:t -*-
(require 'ert)

(require 'ein-worksheet)
(require 'ein-testing-cell)

(defvar ein:testing-worksheet-example-data
  (list (ein:testing-codecell-data "code example input")
        (ein:testing-markdowncell-data "markdown example input")
        (ein:testing-rawcell-data "raw example input")
        (ein:testing-htmlcell-data "html example input")))

(defun ein:testing-worksheet-new ()
  (make-instance 'ein:worksheet))

(defun ein:testing-worksheet-to-json (cells &optional metadata)
  (let* ((ws-0 (ein:worksheet-from-json (ein:testing-worksheet-new)
                                        (list :cells cells
                                              :metadata metadata)))
         (ws-1 (ein:testing-worksheet-new))
         (json-0 (ein:worksheet-to-json ws-0))
         (json-1 (ein:worksheet-to-json
                  (ein:worksheet-from-json ws-1
                                           (ein:json-read-from-string
                                            (ein:json-encode json-0))))))
    (let* ((found (assoc 'metadata json-0)))
      (when found
        (should (cdr found))))
    (should (equal json-0 json-1))))

(ert-deftest ein:worksheet-to-json/empty ()
  (ein:testing-worksheet-to-json nil))

(ert-deftest ein:worksheet-to-json/example-data ()
  (ein:testing-worksheet-to-json ein:testing-worksheet-example-data))

(ert-deftest ein:worksheet-to-json/example-data-with-metadata ()
  (ein:testing-worksheet-to-json ein:testing-worksheet-example-data
                                 '(:name "Worksheet name")))

;;; Short and duplicate cell ids (T058)

(require 'ein-testing-notebook)

(defun eintest:worksheet-notebook-json (&rest ids)
  (json-serialize
   `((cells . ,(vconcat
                (mapcar (lambda (id)
                          `((cell_type . "code") (id . ,id) (metadata . ,(make-hash-table))
                            (source . "x = 1") (outputs . []) (execution_count . :null)))
                        ids)))
     (metadata . ,(make-hash-table)) (nbformat . 4) (nbformat_minor . 5))
   :null-object :null))

(ert-deftest ein:worksheet-short-id ()
  "Ids shorter than five characters load, render and hash without error."
  (ein:testing-with-notebook-json (eintest:worksheet-notebook-json "a" "bc")
    (let ((cells (ein:worksheet-get-cells ein:%worksheet%)))
      (should (equal (mapcar #'ein:cell-id cells) '("a" "bc")))
      (should (equal (mapcar #'ein:worksheet--unique-enough-cell-id cells) '(a bc)))
      ;; Editing runs the which-cell hook, which hashes ids.
      (ein:cell-goto (car cells))
      (insert "y")
      (should (string-prefix-p "y" (ein:cell-get-text (car cells)))))))

(ert-deftest ein:worksheet-duplicate-ids-repaired ()
  "Duplicate ids on load are made unique and a warning is logged."
  (let (warnings)
    (cl-letf* ((orig (symbol-function 'ein:log-wrapper))
               ((symbol-function 'ein:log-wrapper)
                (lambda (level func)
                  (when (eq level 'warn) (push (funcall func) warnings))
                  (funcall orig level func))))
      (ein:testing-with-notebook-json (eintest:worksheet-notebook-json "dup" "dup" "dup")
        (should (equal (mapcar #'ein:cell-id (ein:worksheet-get-cells ein:%worksheet%))
                       '("dup" "dup-1" "dup-2")))))
    (should (cl-some (lambda (w) (string-match-p "Duplicate cell id dup" w)) warnings))))

(ert-deftest ein:worksheet-classic-undo-unchanged ()
  "No-regression guard (T095): the classic view keeps its undo ledger.
Cell input edits are undoable when `ein:worksheet-enable-undo' is
non-nil; structural operations are not; nil disables undo outright."
  (let ((ein:notebook-view 'classic))
    (dolist (enable '(t nil))
      (let ((ein:worksheet-enable-undo enable)
            (last-command nil))
        (with-current-buffer (ein:testing-notebook-make-empty)
          (should (eq buffer-local-enable-undo enable))
          (should (eq (eq buffer-undo-list t) (not enable)))
          (should (eq (and (memq #'ein:worksheet--which-cell-hook after-change-functions) t)
                      enable))
          (call-interactively #'ein:worksheet-insert-cell-above)
          (undo-boundary)
          (insert "some text")
          (undo-boundary)
          (if (not enable)
              (should-error (undo))
            (undo)
            (should (equal "" (ein:cell-get-text (ein:worksheet-get-current-cell)))))
          (setq last-command nil)
          (undo-boundary)
          (call-interactively #'ein:worksheet-delete-cell)
          (should (= 0 (ein:worksheet-ncells ein:%worksheet%)))
          (ignore-errors (undo))
          (should (= 0 (ein:worksheet-ncells ein:%worksheet%))))))))
