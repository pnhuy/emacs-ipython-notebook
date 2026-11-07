;;; -*- mode: emacs-lisp; lexical-binding: t -*-
;;; ein-completer.el --- Completion module

;; Copyright (C) 2018- Takafumi Arakaki / John Miller

;; Author: Takafumi Arakaki <aka.tkf at gmail.com> / John Miller <millejoh at mac.com>

;; This file is NOT part of GNU Emacs.

;; ein-completer.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein-completer.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein-completer.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Kernel completion for the cells view through
;; `completion-at-point-functions': the kernel answers a
;; `complete_request' for the cell source.  The wait for the reply is
;; bounded by `ein:completion-timeout' and ends early on user input.

;;; Code:

(require 'cl-lib)
(require 'ein-core)
(require 'ein-classes)
(require 'ein-kernel)
(require 'ein-cell)

(declare-function ein:nbview--cell-at "ein-nbview")
(declare-function ein:nbview--source-bounds "ein-nbview")

(defvar ein:nbview--view)
(defvar ein:%notebook%)

(make-obsolete-variable 'ein:complete-on-dot nil "0.15.0")
(make-obsolete-variable 'ein:completion-backend nil "0.17.0")

(defcustom ein:completion-timeout 0.5
  "Seconds to wait for the kernel's completion reply."
  :type 'number
  :group 'ein
  :package-version '(ein . "0.18"))

(defun ein:completer--cell-kernel (cell)
  "The kernel of CELL, else of the buffer's notebook."
  (or (ein:oref-safe cell 'kernel)
      (and (ein:$notebook-p ein:%notebook%) (ein:$notebook-kernel ein:%notebook%))))

(defun ein:nbview-completion-at-point ()
  "`completion-at-point-functions' entry: complete from the kernel.
Return nil outside a code cell source, without a live kernel, on an
error reply, or when no reply arrives within `ein:completion-timeout'."
  (when-let* ((view (bound-and-true-p ein:nbview--view))
              (cell (ein:nbview--cell-at (point)))
              ((ein:codecell-p cell))
              (b (ein:nbview--source-bounds view cell))
              ((<= (car b) (point) (cdr b)))
              (kernel (ein:completer--cell-kernel cell))
              ((ein:kernel-live-p kernel)))
    (let* ((s (car b))
           (pos (- (point) s))
           (code (buffer-substring-no-properties s (cdr b)))
           (deadline (+ (float-time) ein:completion-timeout))
           reply)
      (ein:kernel-complete kernel code pos
                           (lambda (content) (setq reply (or content 'none))))
      (while (and (null reply)
                  (< (float-time) deadline)
                  (not (input-pending-p)))
        (accept-process-output nil 0.02))
      (when (and (consp reply) (equal (plist-get reply :status) "ok"))
        (let ((start (+ s (or (plist-get reply :cursor_start) pos)))
              (end (+ s (or (plist-get reply :cursor_end) pos))))
          (list (max s (min start (cdr b)))
                (max s (min end (cdr b)))
                (append (plist-get reply :matches) nil)
                :exclusive 'no))))))

(provide 'ein-completer)

;;; ein-completer.el ends here
