# EIN compatibility status

This file is the evidence-based record of what works in this fork of EIN on
a modern stack. It is updated whenever a finding is fixed or re-verified.
Nothing here is claimed until its regression test passes.

**Tested environment** (see `doc/audit/baseline-2026-11-07.txt`, regenerate
with `sh tools/audit.sh`):

- GNU Emacs 31.1 (Linux)
- jupyter_server 2.21.1, jupyter_client 8.10.0, ipykernel 7.4.0, nbformat 5.11.1,
  JupyterLab 4.6.5; the classic `notebook` package is **not** installed
- Python 3.14.9

**Scoped compatibility statement (Milestone A).** On the tested environment,
EIN is compatible with Jupyter Server 2.21.1 for these operations, each
covered by a passing test: starting and stopping a local server; logging in
with a token or a password, including a custom `base_url`; listing
kernelspecs; opening, executing and saving notebooks; interrupting,
restarting and shutting down kernels; reconnecting after a dropped
connection or a dead kernel; lossless round-trip of the 16-notebook corpus;
and conflict-checked saving (C03, C17, C24–C28, C04, C07, C10). No other
claim is made. JupyterHub, remote servers and Docker mode remain
`untested` (C23). LSP is unsupported in notebook cells (C36, "LSP"). The minimum Emacs is 29.1; CI runs 29.1 and the latest
release.

**Classification labels**

| Label | Meaning |
|---|---|
| `working` | Works and is reusable as is |
| `broken` | Fails, loses data or misbehaves |
| `deprecated-but-functional` | Works, but uses an obsolete API or pattern |
| `architecturally-limited` | Cannot be fixed locally; needs a design change |
| `ui-enhancement` | Works, but is the target of the UI redesign |
| `untested` | Not verified on the tested environment; no claim is made |

## Findings

| id | area | classification | evidence | action | regression test |
|---|---|---|---|---|---|
| C01 | Loading from the clone | `working` | `locate-library "ein"` under the real init → `/home/huypham/projects/emacs-ipython-notebook/lisp/ein.el`; no `ein-*` in `~/.emacs.d/elpa`; 0 `.elc` in `lisp/` (audit baseline) | none | `tools/audit.sh --user-init` |
| C02 | Test harness | `working` | Cask-free `make test-unit`: 222/222 pass in 0.92 s (T006); 227/227 after Phase 3 (T025); 253/253 after US2 (T054); 287/287 after US4 (T071); 313/313 after US3 undo (T099). `make test-integration`: 11/11. Tests use a private `request-storage-directory`, so the user's curl cookie jar cannot leak stale `_xsrf` cookies into them. `test-ein-cell.el` and `test-ein-notebook.el` load now that mocker is installed in `.deps/` | none | `make test-unit` |
| C03 | Open / execute / save (token, localhost) | `working` | Planning smoke run and `test/integration/test-ein-smoke.el` against jupyter_server 2.21.1: open executes nothing, both execution paths return, save passes `nbformat.validate`, ids and `tags` preserved | none | `test-ein-smoke.el` (`:integration`) |
| C04 | Save normalizations | `working` (was `broken`) | Save used to inject `metadata.name` at notebook level and `metadata.collapsed: false` into every cell (research A4). JSON is now read faithfully (arrays as vectors, `{}` kept) and written back unchanged apart from the documented G9 normalizations below | fixed | `ein:roundtrip-*` (16-notebook corpus), `ein:integration-corpus-roundtrip` |
| C05 | Server discovery (`ein:process-refresh-processes`, `ein-process.el:120`) | `working` (was `broken`) | destructured `notebook_dir`; jupyter_server 2.x emits `root_dir` (research A5.1). Now reads `root_dir`, falls back to `notebook_dir`, skips entries with neither (T040) | fixed | `ein:process-refresh-root-dir`, `ein:process-refresh-notebook-dir-legacy` |
| C06 | Default server subcommand (`ein-jupyter.el:91`) | `working` (was `broken`) | default was `"notebook"`, which is not installed (A5.2). Default is now `nil` = auto-detect, probing `jupyter server --version` once per session (T041). Startup waits on a process filter with `ein:jupyter-server-startup-timeout` instead of a blocking poll (T042) | fixed | `ein:jupyter-detect-subcommand-*`, `ein:integration-server-start-stop` |
| C07 | Attachments, unknown keys, `id` on old minors | `working` (was `broken`) | attachments, unknown notebook/cell keys and future minors (`nbformat_minor` 6) are preserved. Notebooks below 4.5 get generated ids and are written as 4.5 (G9b) | fixed | `ein:roundtrip-attachments`, `ein:roundtrip-unknown-keys`, `ein:roundtrip-nb44-no-ids`, `ein:notebook-future-minor-preserved` |
| C08 | Cell identity on move/copy/yank (`ein:cell-convert`) | `working` (was `broken`) | type conversion and move keep id, metadata, outputs and attachments; copy/yank gives a fresh 8-hex id and keeps the rest | fixed | `ein:cell-convert-keeps-identity`, `ein:cell-convert-type-keeps-id`, `ein:cell-copy-yank-fresh-id` |
| C09 | Short and duplicate cell ids | `working` (was `broken`) | ids shorter than 5 characters no longer crash; duplicate ids on load are repaired (`dup`, `dup-1`, `dup-2`) with a warning | fixed | `short-id.ipynb`, `ein:worksheet-short-id`, `ein:worksheet-duplicate-ids-repaired` |
| C10 | Save robustness | `working` (was `broken`) | encoding errors abort the save with a message before any request; the body is always UTF-8; before writing, EIN compares the server's `last_modified` with the value it loaded and asks overwrite / reload / cancel on mismatch; the buffer is marked unmodified only on success; a failed save says "retry with C-x C-s" and keeps the buffer modified. Saving while a cell runs writes `execution_count: null` for that cell. Atomic file replacement on the server relies on jupyter_server `FileContentsManager.use_atomic_writing` (default `true`) | fixed | `test-ein-content.el` (G8/G10), `ein:integration-save-conflict` |
| C11 | Undo of structural operations | `working` in the cells view; `architecturally-limited` in the classic view (unchanged) | classic: parallel ledger `ein:%which-cell%` rewrites `buffer-undo-list`, disables undo globally on mismatch; structural ops bind `buffer-undo-list` to `t` (A5.7). Cells view: the buffer is the model, so the ordinary undo list covers text and structural edits (see "Undo" below) | redesigned in US3 (T096–T099) | `ein:nbview-undo-property` (3 seeds × 60 ops), `ein:nbview-undo-*`, `ein:worksheet-classic-undo-unchanged` |
| C12 | poly-ein global advice | `architecturally-limited` | load-time global advice on `syntax-ppss`, `jit-lock-*`, `font-lock-flush`, `scan-lists`, `other-buffer`, `isearch-done`, `pm-*`; `fmakunbound 'poly-lock-mode` (A5.8) | confine to the classic view (plan Complexity Tracking) | T080 case (e) |
| C13 | Credentials in logs | `working` (was `broken`) | cookie values at `info` (`ein-websocket.el:62`); `raw-header` (`ein-notebooklist.el:739`); hub-token URL in "Login to %s complete"; executed code at debug (`ein-kernel.el:380`); `?token=` URLs in the server buffer (A5.9). Fixed: `ein:log--redact` in every EIN log message, registered secrets (token, password), cookie names only, no `raw-header`, code logged only with `ein:log-include-code`, redacted server buffer (T043–T046). **Limit:** request.el's own `request-log-level`/`request-message-level` set to `debug` dumps raw HTTP bodies, outside EIN's redaction; they default to off | fixed | `ein:log-redact-*`, `ein:kernel-execute-does-not-log-code`, `ein:integration-no-secrets-in-logs` (token-grep over all log buffers: 0 hits) |
| C14 | Inline images | `ui-enhancement` | `ein:output-area-inlined-images` defaults to `nil`, spawning an external viewer (A5.10) | inline by default in the new view (US9) | US9 renderer tests |
| C15 | Completion | `broken` | `ein-completer.el` is a 34-line stub; no `complete_request` (A5.11) | US7 | US7 tests |
| C16 | Private APIs | `deprecated-but-functional` | `ewoc--*` internals (`ein-cell.el:52-90`), `request--curl-cookie-jar`, `pm--*`, global `make-variable-buffer-local` of `parse-sexp-lookup-properties` (A5.12) | contain; avoid in new code | compile gate |
| C17 | Kernel restart | `working` (was `broken`) | was session delete + recreate (A5.13). Now `POST /api/kernels/{id}/restart`, then websocket reconnect; the kernel id is kept. Delete + recreate only on HTTP 404/405 (T047) | fixed | `ein:kernel-restart-check-url`, `ein:integration-kernel-ops` |
| C18 | Kernel/websocket transport, auth/query layer, contents API, server launcher, `ein:notebook-from-json`/`to-json` | `working` | smoke runs (A4) and `test-ein-smoke.el` | reuse as is (A5.14) | `test-ein-smoke.el` |
| C19 | Classic ewoc presentation | `ui-enhancement` | the existing cell UI is ewoc-based and is the target of the new notebook view | new view (US5); classic kept as fallback | US5 tests |
| C20 | Server URL with trailing slash | `working` (was `broken`) | found by T015: `http://127.0.0.1:P/` built `ws://…//api/kernels/…` (HTTP 404), and `…:P/` and `…:P` were separate keys ("No recorded kernelspecs"). `ein:notebooklist-login` now keys every server by its `ein:url` form (T052) | fixed | `ein:notebooklist-login--canonical-key`, `ein:integration-password-login` |
| C21 | nbformat list-form `source` passed straight to EIN | `broken` (narrow) | found by T011: `ein:notebook-from-json` signals `invalid-slot-type ein:markdowncell input string` for list-form `source`. Not reachable through Jupyter Server, whose contents API always rejoins lines | none for the server path; `ein:testing-notebook-from-file` rejoins like the server | `test-ein-fixtures.el` |
| C22 | Login token argument position | `working` (API footgun) | passing the token as the 4th argument of `ein:notebooklist-login` triggers `read-passwd`; the 5th argument works (A4) | document | `test-ein-smoke.el` |
| C23 | JupyterHub, remote (non-localhost) servers, Docker mode | `untested` | not exercised on the tested environment. Only `127.0.0.1` URL login was exercised; no hub or Docker setup was available | verify manually | none yet |
| C24 | Start / stop a local server (`ein:jupyter-server-start`, `-stop`) | `working` | auto-detected `server` subcommand; login callback within 30 s; timers keep running during startup; the process ends on stop | none | `ein:integration-server-start-stop` |
| C25 | Kernel operations: list kernelspecs, execute, interrupt, restart, shut down | `working` | against jupyter_server 2.21.1 with ipykernel 7.4.0 | none | `ein:integration-kernel-ops`, `ein:kernel-*-check-url` |
| C26 | Password login, wrong password | `working` | `--PasswordIdentityProvider.hashed_password` server: 1–2 prompts, open/execute/save, password absent from logs; a wrong password fails with a message and no retry loop in < 15 s. Found by T052: jupyter_server 2.x lists such servers as `"password": false, "token": ""`, which EIN read as "authentication disabled"; an empty token now means "unknown" and EIN probes `/login` | fixed | `ein:integration-password-login`, `ein:integration-wrong-password`, `ein:notebooklist-token-or-password--empty-token-is-unknown` |
| C27 | Custom `base_url` (`/ein-x/`) | `working` | login, list, open, execute, save; every request URL keeps the base path. Found by T052: request.el matches cookie paths exactly, and the server sets `_xsrf` on `/ein-x` (no slash), so REST calls and the websocket got HTTP 403. `ein:query-prepare-header` and `ein:websocket--prepare-cookies` now try both forms | fixed | `ein:integration-base-url` |
| C28 | Connection loss and kernel death | `working` | websocket close → status `disconnected`, notice "Kernel disconnected — C-c C-r to reconnect", buffer stays editable, no auto-reconnect; reconnect restores execution. A killed kernel process (server auto-restarts it, iopub `restarting`) → status `dead`, then `idle` again; no error escapes; buffer stays editable | none | `ein:kernel-unexpected-close-sets-disconnected`, `ein:integration-reconnect-and-kernel-death` |
| C29 | Malformed kernel messages | `working` | invalid JSON, missing `header`/`parent_header`, unknown `msg_type` or `msg_id` are logged (redacted, truncated id) and dropped; nothing escapes into websocket.el (T050) | none | `ein:kernel-malformed-messages` |
| C30 | Execution routing by msg_id | `working` (T038) | interleaved replies of two executions reach their own callbacks | none | `ein:kernel-out-of-order-routing` |
| C31 | Kernel shutdown ownership | `working` | kernels not started by this Emacs, or shared by more than one session, ask before shutdown (T049) | none | `ein:integration-shutdown-foreign-kernel-asks` |
| C32 | Blocking waits (`sleep-for`) | `working` (was `deprecated-but-functional`) | HTTP retries in request callbacks (contents, sessions, kernel session, new notebook) are rescheduled with `run-at-time` instead of `sleep-for`, except under `ein:force-sync`. Command-side wait loops (change kernel, server stop, websocket cookie wait) use `ein:accept-output-for` (T053) | fixed | `test-ein-query.el`, `ein:accept-output-for--waits-full-time-without-sleep` |
| C33 | ob-ein synchronous wait | `architecturally-limited` | `org-babel-execute:ein` must return a result, so `ob-ein.el` still waits in a loop (results sentinel, kernel live, file deletion). The waits use `ein:accept-output-for` and stay interruptible with `C-g`. Plan Complexity Tracking exception "ob-ein synchronous wait" | none | none (exception) |
| C34 | Invalid notebook input | `working` | truncated JSON, missing or non-list `cells`, and nbformat 3 are refused with a user error; no buffer is left behind and nothing is registered as opened | none | `ein:notebook-invalid-*` |
| C35 | Test determinism (SC-010) | `working` | `HOME=$(mktemp -d) make test-unit` passes twice in a row (287/287 both times). No files are left in `/tmp`. The only files written under `HOME` are tool caches: native-comp trampolines in `.emacs.d/eln-cache` and Jupyter's one-time `.jupyter/migrated` marker from tests that probe `jupyter` (T075) | none | `make test-unit` |
| C36 | LSP (eglot) in notebook cells | `architecturally-limited` | T115 spike, 2026-11-07: eglot 1.24.31 with pylsp 1.15.0 does not manage the cells-view buffer or a shadow buffer, because neither visits a file. See "LSP" | none; kernel completion is the supported mechanism (C37) | spike scripts (evaluation only) |
| C37 | Code editing in the cells view | `working` | native font-lock, indentation, sexp motion and comments of the kernel language; kernel completion through `completion-at-point`, also while another cell runs. See "Editing" | new (T109–T114) | `test-ein-nbview-edit.el`, `ein:kernel-complete-request-and-reply`, `ein:integration-nbview-edit-while-running` |

## Round-trip normalizations (G9)

An unedited notebook opened and saved by EIN is semantically equal to its
input except for these documented changes:

- **G9a** Key order and whitespace may differ. Multiline `source`, `text` and
  mime-bundle strings may switch between list and string form; nbformat
  treats both the same, and Jupyter Server already rejoins them.
- **G9b** Notebooks with `nbformat_minor` < 5 get a generated id for each cell
  and are written as 4.5. nbformat 3 and older are refused (C34).
- **G9c** A cell that is still running when the notebook is saved is written
  with `execution_count: null`.

## Byte-compilation warnings

Baseline: **92 warnings** with deps from `~/.emacs.d/elpa` (research A2). With
the isolated `.deps/` the count was **110**, because `ein-gat.el` references
optional magit/with-editor internals (magit is not a dependency and is absent
from `.deps/`).

**Current: 0 warnings.** `make test-compile` (`byte-compile-error-on-warn`)
passes on Emacs 31.1, and so does `ein:compile-no-warnings` (`:compile` tag).
No allowlist was needed; `ein-markdown-mode.el` was fixed in place.

| id | kind | files | status |
|---|---|---|---|
| W01 | obsolete `if-let`/`when-let` (Emacs 31) | many | `working`: `if-let*`/`when-let*` (T018) |
| W02 | two-argument `sleep-for` | `ein-jupyter`, `ein-contents-api`, `ein-kernel`, `ein-notebook`, `ein-notebooklist`, `ob-ein`, `ein-utils`, `ein-websocket` | `working`: single float argument, same duration (T019). Blocking itself is C32 (T053) |
| W03 | keyword slot names in `oref`/`slot-boundp` | `ein-worksheet`, `ein-cell`, `ein-shared-output`, `ein-notebook`, `ein-notification`, `ein-traceback` | `working`: symbol slot names (T020) |
| W04 | invalid `defface`/`defcustom` specs | `ein-cell` (unexpanded `,@` in a quoted face spec; quoted `:inherit`), `ein-markdown-mode` (`natnump`, duplicate `:type`, bare `list`), `ein-notebooklist` (`or`) | `working` (T021). The `ein:cell-output-stderr` face now really gets `:extend t`; before, the `,@` form was silently ignored |
| W05 | missing `lexical-binding`; `eval`-based shr binding | `ein-output-area` | `working`: lexical cookie; `ein:shr-insert-document` uses `cl-progv` over `ein:shr-env`, whose values are taken literally rather than evaluated (T022, test `ein:output-area-shr-lexical`) |
| W06 | `rx-constituents`; `org-redisplay-inline-images` (obsolete in Org 9.8); `cl-return-from` without `cl-defun` | `ein-markdown-mode` (`rx-let-eval`), `ob-ein` (`ob-ein--refresh-inline-images` prefers `org-link-preview-refresh`), `ein-utils` (`ein:find-leftmost-column` is a `cl-defun`) | `working` (T023) |
| W07 | magit/with-editor free variables, unknown functions and slots | `ein-gat` | `working`: `defvar`/`declare-function`; magit-section slots read through `ein:gat--section-slot` (T024). `ein-gat` itself remains `untested` at runtime |
| W08 | EIEIO obsolete `name` argument (runtime) | `ein-classes` (`ein:notification-status` initforms) | `working`: the unused names were dropped; no code reads object names (T024) |

## Undo

- **Cells view:** unified undo/redo for text, insert, delete, move,
  convert, split and merge — verified by property test T093 (3 seeds × 60
  ops). Every undo step restores the exact prior serialization, and
  redoing all steps restores the final one. Each operation class ran at
  least twice per seed.
  - Undo goes back to the as-opened notebook. After that, `undo` signals
    "No further undo information" and the buffer is unmodified again.
  - Undo brings back the same cell object (`eq`), with its id, metadata
    and outputs.
  - An output that arrives while its cell is deleted is kept and shown
    once undo restores the cell.
  - Prompt, output, selection and decoration updates never add undo
    entries. `ein:nbview--assert-no-undo-entries` checks this in the
    tests.
- **Commands:** `undo`, `undo-only` and `undo-redo` are remapped to
  `ein:nbview-undo`, `ein:nbview-undo-only` and `ein:nbview-undo-redo`.
  The wrappers let undo cross the read-only cell headers and footers,
  then call `ein:nbview--reconcile` on the changed region, which
  refreshes prompts and outputs, redecorates and reselects.
  - Checked interactively in terminal Emacs via tmux: `C-/` after typing,
    insert, move and delete returns to the opened notebook, unmodified.
- **Read-only boundaries:** `kill-region` across two cells signals
  `text-read-only` and leaves the buffer unchanged.
- **Split and merge** (`C-c C-s`, `C-c RET`) are single undo steps.
  - Split: the new cell gets a new id. The upper part keeps the id,
    metadata and outputs.
  - Merge: the upper cell keeps its id and metadata; the lower cell's
    outputs are dropped.
- **Deviation from T097:** there are no per-cell overlays to recreate.
  Decorations are text properties, plus one selection overlay that
  reconcile moves.
- T100 (separate structural undo ring) was not needed: T093 passes for
  every operation class.
- **Classic view:** structural operations not undoable (unchanged legacy limitation).
- **undo-tree / vundo:** untested.

## Editing

The cells view keeps one major mode, `ein:nbview-mode`. Language features
are computed in a hidden **shadow buffer** per major mode
(`" *ein-nbview-shadow:MODE*"`) that holds a copy of the cell source.
Shadow buffers run the mode without its hooks and are killed with the last
cells-view buffer.

- **Language:** `metadata.language_info.name`, then
  `metadata.kernelspec.language`, then the kernelspec. The mode comes from
  `ein:nbview-language-modes` (default `python` → `python-mode`), then
  `LANG-mode` if it is a `prog-mode`, else `prog-mode`.
  `major-mode-remap-alist` is honoured. Names from the notebook never call
  a minor mode or a non-programming mode.
- **Highlighting:** `font-lock-fontify-region-function` copies the shadow's
  faces onto each cell source. Markdown cells use `ein:markdown-mode`.
  Sources longer than `ein:nbview-native-fontify-max-chars` (20000) are not
  fontified. Fontification adds no undo entries (tested).
- **Indentation:** `indent-line-function` indents the line in the shadow and
  applies the column with `indent-line-to`; other cells never change.
  `RET` is `ein:nbview-newline` (newline and indent); `TAB` is
  `ein:nbview-indent-or-complete`, which follows `tab-always-indent`.
- **Syntax:** `syntax-propertize-function` gives each source its mode's
  syntax table, so `forward-sexp`, `syntax-ppss` and `comment-dwim` work.
  Comment syntax comes from the notebook language.
- **Completion:** `ein:nbview-completion-at-point` sends a Jupyter
  `complete_request` (`ein:kernel-complete`). It waits at most
  `ein:completion-timeout` (0.5 s) and stops early on user input. With no
  live kernel, an error reply or a timeout it returns nil, so other
  completion functions run.
  - Live test (jupyter_server 2.21.1, ipykernel 7.4.0): `import o`
    completes to `os`. While another cell runs `time.sleep(5)`, inserting
    text takes < 0.1 s and completion returns within the timeout.
- **Non-Python kernels:** a `javascript` notebook uses `js-mode`; an
  unknown language uses `prog-mode`. No Python buffer is created for them.
- **Not provided:** hover/documentation, signature help, diagnostics, go to
  definition and refactoring. See "LSP".

## LSP

**LSP: unsupported (evaluated 2026-11-07, evidence below).** No working
path was found, so there is no follow-up task.

Spike (T115, evaluation only, no feature code) on Emacs 31.1, eglot 1.24.31
and pylsp 1.15.0:

1. **Cells-view buffer.** `buffer-file-name` is nil and the major mode is
   `ein:nbview-mode`. `eglot-ensure` does nothing (`eglot-managed-p` nil,
   no server). `M-x eglot` asks which major mode to manage, because no
   server is associated with `ein:nbview-mode`.
2. **Shadow buffer** (`python-mode`, no file). `M-x eglot` asks the same
   question. With an explicit contact
   (`(eglot 'python-mode '(transient . DIR) 'eglot-lsp-server '("pylsp") 'python)`)
   pylsp connects, but the buffer is **not managed** (`eglot-managed-p`
   nil). Eglot manages only buffers that visit a file, since LSP
   identifies documents by URI.
3. **Control.** The same text in a real `cell.py` file is managed, and
   `eglot-completion-at-point` returns `pardir`, `path`, `pathconf`, ...
   for `os.pa`. The server works; the obstacle is the buffer model.

Other blockers that a file-backed workaround would also hit:

- The notebook buffer mixes languages: code, markdown and outputs.
- Positions from a server (diagnostics, edits, definitions) refer to a
  per-cell or concatenated document. They would have to be mapped back
  into a buffer whose cell offsets change as cells are edited.
- Writing cell sources to temporary files on every change conflicts with
  the safe temporary-file rule and the no-hidden-I/O stance.

Kernel completion (C37) is the supported completion mechanism.

## Platform notes

- Tested on Linux only. macOS and Windows are `untested`.
- On Windows, private temporary directories cannot be restricted to mode
  0700 the same way (plan Complexity Tracking); behaviour there is `untested`.
- Inline images require a graphical Emacs. Terminal Emacs shows placeholders.
- The LaTeX preview uses `latex` plus `dvisvgm` or `dvipng` when present
  (`ein:latex-render-method` `auto`). Without them, or in a terminal, math
  is shown as Unicode text, and constructs without a Unicode form stay
  as written.

## UI review

T091 (SC-004): the cells view (`ein:notebook-view` = `cells`) on
`smoke.ipynb`. Cell 2 had an execution count, stdout and stderr. Each
pass selected it, entered the edit state, inserted a cell below,
moved it up and deleted it. `ein:nbview--check-invariants` held after
every pass. Emacs 31.1 (PGTK), 2026-11-07.

The GUI screenshots came from `emacs -Q` driven by a script that uses
`x-export-frames`. The terminal checks ran `emacs -nw -Q` in tmux
(100×30) and captured the pane with its escape sequences. The
screenshots are not committed.

| check | modus-operandi | modus-vivendi | default (`emacs -Q`) | tty truecolor | tty 8 colours (`TERM=xterm`) |
|---|---|---|---|---|---|
| cell boundaries (bar, header and footer rules) | pass | pass | pass | pass | pass |
| selected vs unselected | pass | pass | pass | pass | pass |
| selected vs editing | pass | pass | pass | pass | pass (after fix 2) |
| source vs output separation | pass | pass | pass | pass | pass |
| after insert / move / delete | pass (after fix 1) | pass (after fix 1) | pass | pass | not re-checked |

Defects found and fixed during the review:

1. Moving a cell collapsed the selection overlay, which then stayed in
   the wrong place. `post-command` did not repair it, because the
   selected cell had not changed. `ein:view-move-cell` now refreshes
   the overlay. The new assertion is in
   `ein:nbview-layout-structural-edits`.
2. The editing bar was weaker than the selected bar: a foreground glyph
   versus `highlight`'s background block. In 8 colours both drew as
   green blocks. `ein:nbview-cell-bar-editing` is now an inverse-video
   `success` block. With fewer than 88 colours it is a bold
   inverse-video block of the default colours.

Known cosmetic limitation: with point at the very end of a source, the
cursor is drawn at the start of the footer's row. This happens because
the footer's `display` string begins with a newline. A `cursor` text
property on that newline did not change it. Editing is unaffected.

Design deviations from tasks.md T087/T088, all deliberate:

- **Rule.** The header rule is a string of `─` characters (`-` when
  `─` cannot be displayed). It is not a `(space :align-to
  right-margin)` stretch, because a stretch glyph cannot carry the
  rule face in a terminal.
- **Decoration mechanism.** Cell decorations are text properties: a
  `line-prefix` and `wrap-prefix` bar, plus `ein:nbview-code-face` via
  `add-face-text-property`. They are applied by jit-lock or by
  re-decorating one cell. There are no per-cell overlays; a single
  overlay (`ein-nbview-selection`) marks the selection.
- **Footer stickiness.** The footer character keeps the default
  stickiness rather than `front-sticky nil`. Text inserted after it
  then inherits `read-only`, so nothing can be typed between cells.
  The header is `front-sticky t` and `rear-nonsticky t`.
- **Typing re-renders.** The T082 typing check allows at most one
  re-render, not exactly one. Ordinary typing re-renders nothing.
- **Mode.** `ein:notebook-mode` is not enabled in a cells buffer.
  `ein:nbview-mode-map` carries the essential bindings. The full
  keymap is US6.
- **Two windows.** Selection is per buffer. With the buffer shown in
  two windows, the selection follows the window of the last command.

## Command and edit states

T126: a keyboard and mouse walkthrough of the cells view
(`ein:nbview-modal` = t) on `smoke.ipynb`, against jupyter_server 2.21.1
with ipykernel 7.4.0. Emacs 31.1, 2026-11-07. Each step was checked by
reading the state, selection, cell types, sources and prompts through
`emacsclient`.

- **Terminal:** `emacs -nw -Q` in tmux (`TERM=xterm-256color`), keys
  sent with `tmux send-keys`.
- **GUI:** the PGTK build on Xvfb with `GDK_BACKEND=x11`, keys and clicks
  sent with `xdotool` (XTEST).

| step | terminal | GUI |
|---|---|---|
| `j` / `k` move the selection; the cursor is hollow | pass | pass |
| typing in the command state changes nothing | pass | pass |
| `RET` edits the selected cell; the cursor is a box | pass | pass |
| typing, `RET` and `TAB` indent Python (`if x:` → 4 spaces) | pass | not repeated |
| `ESC ESC` returns to the command state | pass | not repeated |
| `<escape>` returns to the command state | n/a (see below) | pass |
| `ESC x` is still `M-x` | pass | not repeated |
| `d d` deletes the cell; `z` restores it with its prompt and output | pass | pass |
| `M-<down>` moves the cell; `z` restores the order | pass | pass |
| `M-RET` runs the cell and advances; at the last cell it adds a code cell and edits it | pass | not repeated |
| `C-RET` runs the cell and stays in the command state | n/a (see below) | pass |
| `S-RET` runs and advances | n/a (see below) | pass |
| a click on source text edits that cell | not applicable | pass |
| a click on a header selects the cell in the command state | not applicable | pass |
| a code cell with a syntax error shows its traceback below it | pass | pass |

Terminal notes:

- A terminal sends `ESC` as the Meta prefix, so a single `ESC` waits for
  the next key. **`ESC ESC`** leaves the edit state.
  `ein:nbview-escape-key` adds one more key for it, for example `"C-c
  C-q"` or `"C-["`. `<escape>` exists only in graphical frames.
- Most terminals send the same bytes for `S-RET`, `C-RET` and `RET`.
  In a terminal, use **`M-RET`** to run and advance, and **`C-c C-c`**
  to run the cell.

GUI note: Xvfb has no window manager, so `xdotool key --window` events
were ignored. XTEST events (`xdotool key` with the pointer over the
frame) were delivered.

## Markdown

T137 (quickstart §6 step 4, SC-006, FR-027b): the cells view on a
notebook with a Markdown cell that has headings, emphasis,
strikethrough, inline code, a link, a table, checkboxes, inline and
display LaTeX, and a fenced Python block. A second cell had an image
attachment. Emacs 31.1, TeX Live 2026 `latex` with `dvisvgm` 3.6.1,
2026-11-07. GUI: `emacs -Q` under Xvfb (`GDK_BACKEND=x11`), with
screenshots taken by `x-export-frames`. Terminal: `emacs -nw -Q` in tmux
(100×45, `TERM=xterm-256color`). The screenshots are not committed.

| check | GUI | terminal |
|---|---|---|
| headings, bold, italic, strikethrough, code, link | pass | pass (faces) |
| table drawn with `│` and `┼` | pass | pass |
| checkboxes | pass (☑ ☐) | pass (`[x]` `[ ]`) |
| inline `$e^{i\pi}$` and display `$$…$$` math | pass (SVG images) | pass (Unicode text, `e^{iπ}`, `∫₀¹ x² dx`) |
| fenced code fontified as Python | pass | pass |
| attachment image | pass (inline image) | pass (`[image x]` placeholder) |
| `RET` shows the source; the preview overlay is gone | pass | pass |
| 10 line motions inside the source: no re-render | pass (0) | pass (0) |
| `Esc` restores the preview with exactly one render | pass | pass |
| source unchanged and invariants hold afterwards | pass | pass |

Defects found and fixed during the review:

1. The preview was a `display` string on the source. Emacs ignores
   `display` properties nested in a display string, so images and
   LaTeX SVGs showed as their fallback text. The preview now hides the
   source (`invisible`) and shows the rendering as the overlay's
   `before-string`. `ein:nbview-md-preview-shown` asserts this.
2. Unmapped scripts lost their inner conversion: `e^{i\pi}` stayed
   raw. It now renders as `e^{iπ}` (test `ein:latex-text-fallback`).

Notes:

- No network access happens by default. Remote images show as an
  `[image ALT]` link until `ein:nbview-fetch-remote-images` is set.
- Local image files load only from inside the notebook's directory on a
  local server.
- Raw HTML in Markdown is shown as text and is never interpreted.
- LaTeX runs with `-no-shell-escape` in a private temporary directory,
  which is deleted after each job. Results are cached in
  `ein:latex-cache-directory`.
- `C-c C-v` (`ein:nbview-toggle-markdown-preview`) turns the preview
  off in one buffer; `ein:nbview-markdown-preview` turns it off
  everywhere.

## Outputs

T149 (quickstart §6 step 5, SC-007, FR-031–FR-036): the cells view on a
notebook that nbconvert executed. It holds a matplotlib PNG, an HTML
table with an embedded `<script>`, an SVG with `<script>` and `onload`,
a LaTeX result, a `ZeroDivisionError` traceback, and a 5000-line stream.
Emacs 31.1, matplotlib 3.11.2, 2026-11-07. The GUI and terminal setup
match the Markdown review: Xvfb with `x-export-frames`, and tmux at
100×45. The screenshots are not committed. The integration test
`ein:integration-nbview-rich-outputs` runs the same kinds of output
against a live kernel, then saves, validates with nbformat, and reopens
the notebook.

| check | GUI | terminal |
|---|---|---|
| output shown under its own cell, with the cell bar on every line | pass | pass (`▎`) |
| matplotlib PNG | pass (inline, scaled to `ein:nbview-image-max-width`) | pass (`<Figure size …>` text) |
| HTML table | pass (shr, "42" shown, script dropped) | pass |
| SVG | pass (inline; no `script` or `onload` in the image data) | pass (text representation) |
| LaTeX | pass (SVG image) | pass (Unicode text) |
| traceback readable (`ename: evalue` header, ANSI colours) | pass | pass |
| long stream truncated to 200 lines; expand shows all 5002 | pass | pass |
| `o` collapses to `[outputs hidden]` and back | pass | pass |
| point at the end of the source is drawn on the source line | pass | pass |
| model outputs unchanged; invariants hold; output adds no undo entries | pass | pass |
| outputs survive save and reopen | pass (integration test) | pass (integration test) |

Defects found and fixed during the review:

1. The first output line of the last cell was drawn without the cell
   bar. A line that starts in an `after-string` takes its `line-prefix`
   from the following buffer text, and that text is the next cell or
   nothing at all. The footer is now a `before-string` on the footer
   newline, written as `" \n"` plus the body. Every line starts inside
   the string. The leading space carries the `cursor` property, so
   point at the end of the source is still drawn on that line. Test:
   `ein:nbview-output-footer-lines-own-prefix`.
2. Reopening a notebook after its buffer was killed failed with
   `set-buffer nil`, because the stale opened-notebook entry was reused.
   `ein:notebook-open` now ignores and forgets entries whose buffer is
   dead. Test: `ein:notebook-live-opened-notebook-forgets-killed-buffer`.

Notes:

- `ein:output-area-inlined-images` (classic view) now defaults to `t`
  (T148). The cells view always shows images inline in graphic frames.
- Terminal frames prefer text representations, which is why figures
  and SVGs show as their `text/plain` form there.
- Scripts, event handlers and external references are removed from HTML
  and SVG before rendering. Nothing is fetched over the network.
- The error header repeats the last traceback line. This follows
  contracts/renderers.md, so the header stays visible when the
  traceback is truncated.
- Output rendering never touches the buffer text or the undo list.
- `ein:latex-cache-directory` defaults to a directory under
  `user-emacs-directory`. An `emacs -Q` review run therefore writes its
  cache to `~/.emacs.d/ein/latex-cache/`.

## Toolbar

T157 (US8, FR-040–FR-043): the notebook toolbar in the header line, the
selected-cell toolbar, and the kernel status, on `smoke.ipynb` with the
test kernel stub. Emacs 31.1, 2026-11-07. The GUI and terminal setup
match the earlier reviews: Xvfb with `x-export-frames` at 84 columns,
and tmux at 100×45. Mouse clicks are sent through each button's own
`keymap` property (`[header-line mouse-1]` or `[mouse-1]`). Keys are
sent with `execute-kbd-macro` in command state. Each command was
stubbed to record that it ran and which cell it acted on.

| check | GUI | terminal |
|---|---|---|
| header line: Run All, Restart, Interrupt, Add Code, Add Markdown, Save, kernel name, status | pass (symbols) | pass (`[Run All]`-style ASCII) |
| every toolbar button runs its command by mouse and has a tooltip | pass | pass |
| short labels (`▶▶ ↻ ■ ＋C ＋M 💾`) when the full toolbar does not fit the window | pass | n/a (fits in 100 columns) |
| only the selected cell has a toolbar: Run, Add, Delete, Up, Down, More | pass (`▶ ＋ ✕ ↑ ↓ ⋯`) | pass (`[Run] [+] [x] [^] [v] [...]`) |
| a cell toolbar click acts on the clicked cell | pass | pass |
| the cell toolbar follows the selection (`j`) | pass | pass |
| the header rule is shortened so that the cell toolbar fits on one line | pass | pass |
| keys: `C-c C-f` run all, `C-c C-x C-k` select kernel, `C-c C-x C-r` restart, `C-c C-z` interrupt, `C-x C-s` save, `C-c C-c` run, `C-c C-b` add, `C-c C-k` delete, `C-c <up>`/`<down>` move, `M-x ein:nbview-more-actions` | pass | pass |
| busy, idle and disconnected show in the header line and as `[STATUS]` in the mode line, with no cell re-rendered | pass | pass |
| invariants hold | pass | pass |

Notes:

- Every button runs an ordinary command, so the toolbars can be turned
  off with `ein:nbview-toolbar` and `ein:nbview-cell-toolbar`. Nothing
  is lost when they are off.
- More Actions offers: change type, split, merge, clear output,
  collapse input or output, expand truncated output, copy source, copy
  output, and view output.
- Notebook and kernel messages (for example "Kernel busy...") come
  after the toolbar. They may be cut off in narrow windows, and they
  never change the toolbar labels.
- The toolbar on the cell under the mouse (`ein:nbview-toolbar-on-hover`)
  needs a real pointer, so it was not exercised in these batch runs.
- With `emacs -nw`, mouse clicks need `xterm-mouse-mode`. The terminal
  row above was checked through the keymap and not with a physical mouse.
