==========================================================
 EIN -- Emacs IPython Notebook |build-status| |melpa-dev|
==========================================================

.. image:: https://github.com/dickmao/emacs-ipython-notebook/blob/master/thumbnail.png
   :target: https://youtu.be/8VzWc9QeOxE
   :alt: Kaggle Notebooks in AWS

Emacs IPython Notebook (EIN), despite its name, is a jupyter client for all
languages.  It does not work under non-WSL Windows environments.

As of 2023, EIN has been sunset for a number of years having been
unable to keep up with jupyter's web-first ecosystem.  Even during
its heyday EIN never fully reconciled emac's monolithic buffer
architecture to the notebook's by-cell discretization, leaving
gaping functional holes like crippled undo.

**As of 2025, a greenfield notebook implementation resides at,**

https://github.com/commercial-emacs/xjupyter.git

It features full-fledged undo and relies on "mode overlays"
instead of the complex and fragile polymode.

.. |build-status|
   image:: https://github.com/millejoh/emacs-ipython-notebook/workflows/CI/badge.svg
   :target: https://github.com/millejoh/emacs-ipython-notebook/actions
   :alt: Build Status
.. |melpa-dev|
   image:: https://melpa.org/packages/ein-badge.svg
   :target: http://melpa.org/#/ein
   :alt: MELPA current version
.. _Jupyter: http://jupyter.org
.. _Babel: https://orgmode.org/worg/org-contrib/babel/intro.html
.. _Org: https://orgmode.org
.. _[tkf]: http://tkf.github.io
.. _[gregsexton]: https://github.com/gregsexton/ob-ipython

Install
=======
As described in `Getting started`_, ensure melpa's whereabouts in ``init.el`` or ``.emacs``::

   (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))

Then

::

   M-x package-install RET ein RET

Alternatively, directly clone this repo and ``make install``.

EIN detects whether ``jupyter server`` or the legacy ``jupyter notebook``
subcommand is installed.  To force one::

   M-x customize-option RET ein:jupyter-server-use-subcommand RET

Requirements
============
* GNU Emacs 29.1 or later.  29.1 provides what the notebook view relies on:
  ``string-pixel-width`` and ``pixel-fill-region`` (29), ``undo-redo`` (28),
  native JSON and image ``:max-width``/``:max-height`` (27).
* Jupyter Server 2.x with ``ipykernel``.  ``nbformat`` is needed only to run
  the tests.

Development
===========
Load EIN from a local clone, ahead of any installed copy::

   (use-package ein
     :ensure nil
     :load-path "~/projects/emacs-ipython-notebook/lisp")

Confirm with ``M-: (locate-library "ein")``, which must point into the clone.

Run ``make autoloads`` once after cloning, and again after a pull that adds
commands.  It writes the git-ignored ``lisp/ein-autoloads.el``, which
``(require 'ein)`` loads; without it ``M-x ein:login`` and ``M-x ein:run``
are undefined.

Do not leave ``.elc`` files in ``lisp/``: they shadow edited sources.
``make test-compile`` compiles copies in ``.build/``.  If you do compile in
place, set ``load-prefer-newer`` to ``t``.

After editing a file, re-evaluate it (``M-x eval-buffer``) for function
changes.  Changes to ``defvar``/``defcustom`` defaults, macros or EIEIO
classes need ``M-x unload-feature`` and a reload, or simply an Emacs restart.
Close open notebooks first.

Make targets (none of them read ``~/.emacs.d``; dependencies go to ``.deps/``):

``make deps``
   install dependencies into ``.deps/elpa``
``make test-unit``
   unit tests, no Jupyter server needed
``make test-integration``
   tests tagged ``:integration``; each starts a private ``jupyter server``
``make test-compile``
   byte-compile with warnings as errors
``make lint``
   package-lint on the main and new files
``make test-int-legacy``
   the original ecukes/Cask integration suite

Select test files with ``EIN_TEST_FILES="test/test-ein-cell.el" make test-unit``.

Tested with Emacs 31.1, jupyter_server 2.21.1, ipykernel 7.4.0, nbformat
5.11.1 and Python 3.14.9 on Linux.  CI runs Emacs 29.1 and the latest
release with Python 3.12.  See ``doc/compatibility.md`` for what has been
verified.

Usage
=====
Start EIN using **ONE** of the following:

* Open an ``.ipynb`` file, press ``C-c C-o``, or,
* ``M-x ein:run`` launches a jupyter process from emacs, or,
* ``M-x ein:login`` to a running jupyter server, or,

``M-x ein:stop`` prompts to halt local and remote jupyter services.

Alternatively, ob-ein_.

.. _Cask: https://cask.readthedocs.io/en/latest/guide/installation.html
.. _Getting started: http://melpa.org/#/getting-started

Cells view
==========
Notebooks open in the *cells view* (``ein:notebook-view`` is ``cells``).
Each cell is a separate block: a header with its type and execution count,
the source, and the outputs directly below.  Cells are edited in place, in
one buffer, with the major mode of the notebook language providing
highlighting and indentation.  Markdown cells show a rendered preview until
you edit them.

The view has two states, as in Jupyter:

* **Command state** (the default): keys act on cells.  ``j``/``k`` select the
  next/previous cell; printable keys never insert text.
* **Edit state**: ``RET`` (or a click on the source) edits the selected cell.
  Typing is ordinary Emacs editing; ``<escape>`` returns to command state.

Walkthrough
-----------
1. Open a notebook (``M-x ein:run`` or ``M-x ein:login``, then pick it in
   the notebook list).  Nothing is executed on open.
2. Press ``b`` to add a code cell below, ``RET`` to edit it, and type
   ``import math; math.pi``.
3. Press ``S-RET``: the cell runs, its output appears below it, and the next
   cell is selected (one is created at the end of the notebook).
4. Press ``m`` to turn a cell into Markdown, ``RET`` to write ``# Title``,
   then ``<escape>``: the preview shows the heading.
5. ``C-/`` (or ``z`` in command state) undoes text edits and cell inserts,
   deletes, moves, type changes, splits and merges.
6. ``C-x C-s`` saves.

Keys
----
Command state (``ein:nbview-command-map``):

=============================  ==========================================
Key                            Command
=============================  ==========================================
``RET``                        edit the selected cell
``<escape>``                   stay in command state
``j`` / ``<down>``             next cell
``k`` / ``<up>``               previous cell
``a`` / ``b``                  insert a code cell above / below
``d d``                        delete the cell
``m`` / ``y``                  convert to Markdown / code
``S-RET``                      run and advance
``C-RET``                      run in place
``z``                          undo
``M-<up>`` / ``M-<down>``      move the cell up / down
``o`` / ``O``                  collapse or expand outputs / source
``?``                          show the bindings
=============================  ==========================================

Edit state (``ein:nbview-edit-map``); every other key edits as usual:

=============================  ==========================================
Key                            Command
=============================  ==========================================
``<escape>``, ``ESC ESC``      back to command state (restores the preview)
``S-RET``                      run and advance
``C-RET``                      run in place
``RET``                        newline and indent
``TAB``                        indent or complete (``tab-always-indent``)
=============================  ==========================================

Both states (``ein:nbview-mode-map``):

=================================  ==========================================
Key                                Command
=================================  ==========================================
``C-c C-c``                        run the cell
``M-RET``                          run and advance
``C-c C-f``                        run all cells
``C-c C-a`` / ``C-c C-b``          insert a cell above / below
``C-c C-k``                        delete the cell
``C-c C-w`` / ``C-c C-y``          copy the cell / paste it below
``C-c C-n`` / ``C-c C-p``          next / previous cell
``C-c <up>`` / ``C-c <down>``      move the cell up / down
``C-c C-s`` / ``C-c RET``          split at point / merge with the cell below
``C-c C-t``                        toggle code / Markdown
``C-c C-v``                        toggle the Markdown preview
``C-c C-e``                        collapse or expand outputs
``C-c C-l`` / ``C-c C-S-l``        clear outputs of the cell / of all cells
``C-c C-o v`` (``C-c C-o C-o``)    view the cell's outputs in a buffer
``C-c C-o c`` (``C-c C-o M-w``)    copy the cell's output text
``C-c C-$``                        show the cell's traceback
``C-c C-z``                        interrupt the kernel
``C-c C-r``                        reconnect
``C-c C-x C-r``                    restart the kernel
``C-c C-x C-k``                    select the kernel
``C-x C-s`` / ``C-x C-w``          save / save under a new name
=================================  ==========================================

``undo``, ``undo-only`` and ``undo-redo`` are remapped, so their usual keys
work.  All keymaps are ordinary variables that can be changed with
``keymap-set``.  In graphical Emacs, the header line holds a notebook
toolbar (Run All, Restart, Interrupt, Add Code, Add Markdown, Save, kernel
status) and the selected cell shows Run, Add, Delete, Move and More buttons;
every button has a tooltip and a key.

Customization
-------------
``M-x customize-group RET ein-nbview``.  The main options:

=============================================  ==========================================
Variable (default)                             Meaning
=============================================  ==========================================
``ein:notebook-view`` (``cells``)              ``cells`` or ``classic``
``ein:nbview-modal`` (``t``)                   command and edit states; ``nil``: only the ``C-c`` keys
``ein:nbview-escape-key`` (``nil``)            an extra key that leaves edit state
``ein:nbview-mouse`` (``t``)                   ``mouse-1`` selects and edits cells
``ein:nbview-cell-spacing`` (``1``)            blank lines between cells
``ein:nbview-markdown-preview`` (``t``)        preview Markdown cells when not editing
``ein:nbview-language-modes``                  language to major mode (``python`` to ``python-mode``)
``ein:nbview-native-fontify-max-chars``        longer sources are not highlighted (20000)
``ein:nbview-inline-images`` (``t``)           show image outputs inline
``ein:nbview-image-max-width`` (``0.9``)       fraction of the window, or pixels
``ein:nbview-image-max-height`` (``600``)      pixels
``ein:nbview-mime-priority``                   preferred output representations
``ein:nbview-output-max-lines`` (``200``)      longer outputs are truncated (``nil``: no limit)
``ein:nbview-output-coalesce-delay``           seconds to batch rapid outputs (0.05)
``ein:nbview-fetch-remote-images`` (``nil``)   fetch ``http(s)`` images in Markdown
``ein:nbview-remote-image-max-bytes``          size limit for fetched images (5 MiB)
``ein:nbview-toolbar`` (``t``)                 notebook toolbar in the header line
``ein:nbview-cell-toolbar`` (``t``)            toolbar on the selected cell
``ein:nbview-toolbar-on-hover`` (``t``)        also on the cell under the mouse
``ein:latex-render-method`` (``auto``)         ``auto``, ``image`` or ``text``
``ein:latex-scale`` (``1.0``)                  size of LaTeX images
``ein:latex-max-processes`` (``2``)            concurrent LaTeX processes
``ein:latex-timeout`` (``20``)                 seconds before a LaTeX process is stopped
``ein:latex-cache-directory``                  rendered formulas (``~/.emacs.d/ein/latex-cache/``)
``ein:completion-timeout`` (``0.5``)           seconds to wait for kernel completion
``ein:log-include-code`` (``nil``)             include executed code in debug logs
=============================================  ==========================================

Hooks: ``ein:nbview-enter-edit-hook`` and ``ein:nbview-leave-edit-hook``.

LaTeX (optional)
----------------
Formulas in Markdown and LaTeX outputs are rendered as images when
``latex`` and ``dvisvgm`` (or ``dvipng``) are installed, for example from
TeX Live.  Without them, or in a terminal, formulas are shown as Unicode
text (``e^{iπ}``); constructs without a Unicode form stay as written.  Set
``ein:latex-render-method`` to ``text`` to never start a process.

Security
--------
* Opening a notebook never executes code; cells run only on a run command.
* Scripts, event handlers and external references are removed from HTML and
  SVG outputs before rendering.
* Nothing is fetched over the network by default.  Remote Markdown images
  show as links until ``ein:nbview-fetch-remote-images`` is set.
* Tokens, passwords and cookies are redacted from EIN's logs; executed code
  is logged only with ``ein:log-include-code``.
* LaTeX runs in a private (mode 700) temporary directory, deleted after
  every job.

Classic view
------------
``(setq ein:notebook-view 'classic)`` restores the original ewoc and
polymode interface for notebooks opened afterwards.  The classic view
is **deprecated**: it still works and is not removed, but it gets no
new features, and opening a notebook in it shows a warning once per
session.  Its keys are listed under "Keymap (C-h m)" below.

Limitations
-----------
From ``doc/compatibility.md``:

* LSP (eglot) in notebook cells is unsupported: eglot manages only buffers
  that visit a file, and the cells view is not one.  Kernel completion is
  the supported completion mechanism.
* Hover/documentation, signature help, diagnostics, go to definition and
  refactoring are not provided.
* The toolbar on the cell under the mouse (``ein:nbview-toolbar-on-hover``)
  is best-effort: it needs a graphical frame with a real pointer.
* Outputs are display text, not buffer text: use ``C-c C-o c`` to copy them
  and ``C-c C-o v`` to view (and search) them in a buffer.
* Classic view: structural operations not undoable (unchanged legacy
  limitation).
* JupyterHub, remote (non-localhost) servers and Docker mode are untested.
* undo-tree / vundo: untested.
* Tested on Linux only.  macOS and Windows are untested.

FAQ
===

How do I...
-----------

... report a bug?
   Note EIN is tested only for *released* GNU Emacs versions
   29.1
   and later.  Pre-release versions will not work.

   First try ``emacs -Q -f package-initialize -f ein:dev-start-debug`` and reproduce the bug.  The ``-Q`` skips any user configuration that might interfere with EIN.

   Then file an issue using ``M-x ein:dev-bug-report-template``.

... display images inline?
   The cells view shows images inline in graphical Emacs (``ein:nbview-inline-images``).  The classic view does so too by default (``ein:output-area-inlined-images``); set it to ``nil`` to spawn an external viewer instead.

... configure the external image viewer?
   ::

      M-x customize-group RET mailcap
      Mailcap User Mime Data

   On a typical Linux system, one might configure a viewer for MIME Type ``image/png`` as a shell command ``convert %s -background white -alpha remove -alpha off - | display -immutable``.

... get IDE-like behavior?
   In the cells view, code cells get their language's highlighting and indentation, and ``TAB`` completes through the kernel.  LSP (eglot) is not supported in notebook cells; see Limitations.

.. _Issues: https://github.com/millejoh/emacs-ipython-notebook/issues
.. _prevailing documentation: http://millejoh.github.io/emacs-ipython-notebook
.. _spacemacs layer: https://github.com/syl20bnr/spacemacs/tree/master/layers/%2Blang/ipython-notebook
.. _company-mode: https://github.com/company-mode/company-mode
.. _jupyterhub: https://github.com/jupyterhub/jupyterhub
.. _elpy: https://melpa.org/#/elpy
.. _math-preview: https://gitlab.com/matsievskiysv/math-preview
.. _program modes: https://www.gnu.org/software/emacs/manual/html_node/emacs/Program-Modes.html
.. _undo boundaries: https://www.gnu.org/software/emacs/manual/html_node/elisp/Undo.html

ob-ein
======
Configuration:

::

   M-x customize-group RET org-babel
   Org Babel Load Languages:
     Insert (ein . t)
     For example, '((emacs-lisp . t) (ein . t))

Snippet:

::

   #+BEGIN_SRC ein-python :session localhost
     import numpy, math, matplotlib.pyplot as plt
     %matplotlib inline
     x = numpy.linspace(0, 2*math.pi)
     plt.plot(x, numpy.sin(x))
   #+END_SRC

The ``:session`` is the notebook url, e.g., ``http://localhost:8888/my.ipynb``, or simply ``localhost``, in which case org evaluates anonymously.  A port may also be specified, e.g., ``localhost:8889``.

*Language* can be ``ein-python``, ``ein-r``, or ``ein-julia``.  **The relevant** `jupyter kernel`_ **must be installed before use**.  Additional languages can be configured via::

   M-x customize-group RET ein
   Ob Ein Languages

.. _polymode: https://github.com/polymode/polymode
.. _ob-ipython: https://github.com/gregsexton/ob-ipython
.. _scimax: https://github.com/jkitchin/scimax
.. _jupyter kernel: https://github.com/jupyter/jupyter/wiki/Jupyter-kernels

.. _gat utility: https://dickmaogat.readthedocs.io/en/latest/install.html
.. _gat usage: https://dickmaogat.readthedocs.io/en/latest/usage.html
.. _batch mode: https://nbconvert.readthedocs.io/en/latest/execute_api.html
.. _dickmao/Kaggler: https://github.com/dickmao/Kaggler/tree/gcspath#importing-datasets

Keymap (C-h m)
==============

::

   Key             Binding
   -------------------------------------------------------------------------------
   C-<down>	ein:worksheet-goto-next-input-km
   C-<up>		ein:worksheet-goto-prev-input-km
   M-S-<return>	ein:worksheet-execute-cell-and-insert-below-km
   M-<down>	ein:worksheet-not-move-cell-down-km
   M-<up>		ein:worksheet-not-move-cell-up-km
   
   C-x C-s		ein:notebook-save-notebook-command-km
   C-x C-w		ein:notebook-rename-command-km
   
   M-RET		ein:worksheet-execute-cell-and-goto-next-km
   M-,		ein:pytools-jump-back-command
   M-.		ein:pytools-jump-to-source-command
   
   C-c C-a		ein:worksheet-insert-cell-above-km
   C-c C-b		ein:worksheet-insert-cell-below-km
   C-c C-c		ein:worksheet-execute-cell-km
   C-u C-c C-c    		ein:worksheet-execute-all-cells
   C-c C-e		ein:worksheet-toggle-output-km
   C-c C-f		ein:file-open-km
   C-c C-k		ein:worksheet-kill-cell-km
   C-c C-l		ein:worksheet-clear-output-km
   C-c RET		ein:worksheet-merge-cell-km
   C-c C-n		ein:worksheet-goto-next-input-km
   C-c C-o		ein:notebook-open-km
   C-c C-p		ein:worksheet-goto-prev-input-km
   C-c C-q		ein:notebook-kill-kernel-then-close-command-km
   C-c C-r		ein:notebook-reconnect-session-command-km
   C-c C-s		ein:worksheet-split-cell-at-point-km
   C-c C-t		ein:worksheet-toggle-cell-type-km
   C-c C-u		ein:worksheet-change-cell-type-km
   C-c C-v		ein:worksheet-set-output-visibility-all-km
   C-c C-w		ein:worksheet-copy-cell-km
   C-c C-y		ein:worksheet-yank-cell-km
   C-c C-z		ein:notebook-kernel-interrupt-command-km
   C-c C-S-l	ein:worksheet-clear-all-output-km
   C-c C-#		ein:notebook-close-km
   C-c C-$		ein:tb-show-km
   C-c C-/		ein:notebook-scratchsheet-open-km
   C-c C-;		ein:shared-output-show-code-cell-at-point-km
   C-c <down>	ein:worksheet-move-cell-down-km
   C-c <up>	ein:worksheet-move-cell-up-km
   
   C-c C-x C-r	ein:notebook-restart-session-command-km
   
   C-c M-w		ein:worksheet-copy-cell-km
   
   
   This is a minor mode.  If called interactively, toggle the ‘Ein:Notebook
   mode’ mode.  If the prefix argument is positive, enable the mode, and if
   it is zero or negative, disable the mode.
   
   If called from Lisp, toggle the mode if ARG is ‘toggle’.  Enable the
   mode if ARG is nil, omitted, or is a positive number.  Disable the mode
   if ARG is a negative number.
   
   To check whether the minor mode is enabled in the current buffer,
   evaluate the variable ‘ein:notebook-mode’.
   
   The mode’s hook is called both when the mode is enabled and when it is
   disabled.
