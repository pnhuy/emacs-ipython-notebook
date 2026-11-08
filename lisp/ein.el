;;; ein.el --- Jupyter notebook client    -*- lexical-binding:t -*-

;; Copyright (C) 2012-2019 The Authors of the Emacs IPython Notebook (EIN)

;; Authors:  dickmao <github id: dickmao>
;;           John Miller <millejoh at millejoh.com>
;;           Takafumi Arakaki <aka.tkf at gmail.com>
;; Version: 0.18.0pre
;; Package-Requires: ((emacs "29.1") (websocket "1.12") (anaphora "1.0.4") (request "0.3.3") (deferred "0.5") (polymode "0.2.2") (dash "2.13.0") (with-editor "0pre"))
;; URL: https://github.com/dickmao/emacs-ipython-notebook
;; Keywords: tools, jupyter, literate programming, reproducible research

;; This file is NOT part of GNU Emacs.

;; ein.el is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; ein.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with ein.el.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Emacs IPython Notebook (EIN), despite its name, is a jupyter client for all
;; languages.  It does not work under non-WSL Windows environments.
;;
;; This fork adds a cells view, the default: each cell is a separate block
;; edited in place, Markdown cells show a preview until you edit them, and
;; outputs (text, tracebacks, images, tables, LaTeX) appear under their cell.
;; Command and edit states give Jupyter-style keys, and undo covers text
;; edits and cell inserts, deletes, moves, type changes, splits and merges.
;; It is tested against Jupyter Server 2.x on Linux.  LSP (eglot) is not
;; supported in cells; see Limitations.
;;
;; Upstream EIN was sunset in 2023.  Its original interface is kept as the
;; classic view, with its old limitations, such as structural edits that
;; cannot be undone.  Upstream's maintainer has since started a separate
;; client, https://github.com/commercial-emacs/xjupyter.git.

;;; Code:

(when (boundp 'mouse-buffer-menu-mode-groups)
  (add-to-list 'mouse-buffer-menu-mode-groups
               '("^ein:" . "ein")))

;; A package install loads ein-autoloads.el at activation; a clone on
;; `load-path' does not, so `(require 'ein)' leaves `ein:login' and
;; `ein:run' undefined.  Load it here when `make autoloads' made it.
(require 'ein-autoloads nil t)

(provide 'ein)

;;; ein.el ends here
