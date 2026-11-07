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
| C02 | Test harness | `working` | Cask-free `make test-unit`: 222/222 pass in 0.92 s (T006); 227/227 after Phase 3 (T025). `test-ein-cell.el` (18) and `test-ein-notebook.el` (78) load now that mocker is installed in `.deps/` | none | `make test-unit` |
| C03 | Open / execute / save (token, localhost) | `working` | Planning smoke run and `test/integration/test-ein-smoke.el` against jupyter_server 2.21.1: open executes nothing, both execution paths return, save passes `nbformat.validate`, ids and `tags` preserved | none | `test-ein-smoke.el` (`:integration`) |
| C04 | Save normalizations | `broken` | Save injects `metadata.name` at notebook level and `metadata.collapsed: false` into every cell, including markdown (research A4) | fix in US4 | US4 round-trip corpus |
| C05 | Server discovery (`ein:process-refresh-processes`, `ein-process.el:120`) | `broken` | destructures `notebook_dir`; jupyter_server 2.x emits `root_dir` (research A5.1) | fix in US2 | T027 |
| C06 | Default server subcommand (`ein-jupyter.el:91`) | `broken` | default `"notebook"`; the `notebook` package is not installed, so `ein:run` fails without user configuration (A5.2) | detect `server` in US2 | T028 |
| C07 | Attachments, unknown keys, `id` on old minors | `broken` | `ein-cell.el:932-960`, `ein-notebook.el:481-514` drop attachments and unknown keys, and write `id` regardless of `nbformat_minor` (A5.3) | fix in US4 | US4 corpus |
| C08 | Cell identity on move/copy/yank (`ein:cell-convert`, `ein-cell.el:284`) | `broken` | creates a fresh id and drops metadata, execution count and collapsed state (A5.4) | fix in US4 | US4 unit tests |
| C09 | Short cell ids (`ein-worksheet.el:75`) | `broken` | `(substring id 0 5)` crashes on ids shorter than 5 characters, which nbformat allows (A5.5) | fix in US4 | `short-id.ipynb` fixture |
| C10 | Save robustness (`ein-contents-api.el:109-121,232-246`) | `broken` | encode wrapped in `ignore-errors` can send a `nil` body; encoded with the buffer's coding system; no `last_modified` conflict check (A5.6) | fix in US4 | G8/G10 tests |
| C11 | Undo of structural operations | `architecturally-limited` | parallel ledger `ein:%which-cell%` rewrites `buffer-undo-list`, disables undo globally on mismatch; structural ops bind `buffer-undo-list` to `t` (A5.7) | redesign in US3 | T093 (claims policy: no undo claim before T093/T101) |
| C12 | poly-ein global advice | `architecturally-limited` | load-time global advice on `syntax-ppss`, `jit-lock-*`, `font-lock-flush`, `scan-lists`, `other-buffer`, `isearch-done`, `pm-*`; `fmakunbound 'poly-lock-mode` (A5.8) | confine to the classic view (plan Complexity Tracking) | T080 case (e) |
| C13 | Credentials in logs | `broken` | cookie values at `info` (`ein-websocket.el:62`); `raw-header` (`ein-notebooklist.el:739`); hub-token URL in "Login to %s complete"; executed code at debug (`ein-kernel.el:380`); `?token=` URLs in the server buffer (A5.9) | redact in US2 | T029, T030 |
| C14 | Inline images | `ui-enhancement` | `ein:output-area-inlined-images` defaults to `nil`, spawning an external viewer (A5.10) | inline by default in the new view (US9) | US9 renderer tests |
| C15 | Completion | `broken` | `ein-completer.el` is a 34-line stub; no `complete_request` (A5.11) | US7 | US7 tests |
| C16 | Private APIs | `deprecated-but-functional` | `ewoc--*` internals (`ein-cell.el:52-90`), `request--curl-cookie-jar`, `pm--*`, global `make-variable-buffer-local` of `parse-sexp-lookup-properties` (A5.12) | contain; avoid in new code | compile gate |
| C17 | Kernel restart | `broken` | implemented as session delete + recreate instead of `POST /api/kernels/{id}/restart`; the kernel id changes and other clients are affected (A5.13) | US2 | T03x restart test |
| C18 | Kernel/websocket transport, auth/query layer, contents API, server launcher, `ein:notebook-from-json`/`to-json` | `working` | smoke runs (A4) and `test-ein-smoke.el` | reuse as is (A5.14) | `test-ein-smoke.el` |
| C19 | Classic ewoc presentation | `ui-enhancement` | the existing cell UI is ewoc-based and is the target of the new notebook view | new view (US5); classic kept as fallback | US5 tests |
| C20 | Server URL with trailing slash | `broken` | found by T015: logging in with `http://127.0.0.1:P/` builds `ws://127.0.0.1:P//api/kernels/…`, and the websocket gets HTTP 404 | fix URL joining in US2 | T039 (base path), `test-ein-smoke.el` comment |
| C21 | nbformat list-form `source` passed straight to EIN | `broken` (narrow) | found by T011: `ein:notebook-from-json` signals `invalid-slot-type ein:markdowncell input string` for list-form `source`. Not reachable through Jupyter Server, whose contents API always rejoins lines | none for the server path; `ein:testing-notebook-from-file` rejoins like the server | `test-ein-fixtures.el` |
| C22 | Login token argument position | `working` (API footgun) | passing the token as the 4th argument of `ein:notebooklist-login` triggers `read-passwd`; the 5th argument works (A4) | document | `test-ein-smoke.el` |
| C23 | LSP, JupyterHub, remote (non-localhost) servers, Docker mode | `untested` | not exercised on the tested environment | verify manually; LSP verified only by T115 | none yet |

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
| W02 | two-argument `sleep-for` | `ein-jupyter`, `ein-contents-api`, `ein-kernel`, `ein-notebook`, `ein-notebooklist`, `ob-ein`, `ein-utils`, `ein-websocket` | `working`: single float argument, same duration (T019). Blocking itself is T055 |
| W03 | keyword slot names in `oref`/`slot-boundp` | `ein-worksheet`, `ein-cell`, `ein-shared-output`, `ein-notebook`, `ein-notification`, `ein-traceback` | `working`: symbol slot names (T020) |
| W04 | invalid `defface`/`defcustom` specs | `ein-cell` (unexpanded `,@` in a quoted face spec; quoted `:inherit`), `ein-markdown-mode` (`natnump`, duplicate `:type`, bare `list`), `ein-notebooklist` (`or`) | `working` (T021). The `ein:cell-output-stderr` face now really gets `:extend t`; before, the `,@` form was silently ignored |
| W05 | missing `lexical-binding`; `eval`-based shr binding | `ein-output-area` | `working`: lexical cookie; `ein:shr-insert-document` uses `cl-progv` over `ein:shr-env`, whose values are taken literally rather than evaluated (T022, test `ein:output-area-shr-lexical`) |
| W06 | `rx-constituents`; `org-redisplay-inline-images` (obsolete in Org 9.8); `cl-return-from` without `cl-defun` | `ein-markdown-mode` (`rx-let-eval`), `ob-ein` (`ob-ein--refresh-inline-images` prefers `org-link-preview-refresh`), `ein-utils` (`ein:find-leftmost-column` is a `cl-defun`) | `working` (T023) |
| W07 | magit/with-editor free variables, unknown functions and slots | `ein-gat` | `working`: `defvar`/`declare-function`; magit-section slots read through `ein:gat--section-slot` (T024). `ein-gat` itself remains `untested` at runtime |
| W08 | EIEIO obsolete `name` argument (runtime) | `ein-classes` (`ein:notification-status` initforms) | `working`: the unused names were dropped; no code reads object names (T024) |

## Platform notes

- Tested on Linux only. macOS and Windows are `untested`.
- On Windows, private temporary directories cannot be restricted to mode
  0700 the same way (plan Complexity Tracking); behaviour there is `untested`.
- Inline images require a graphical Emacs. Terminal Emacs shows placeholders.
- The LaTeX preview uses `latex` plus `dvisvgm` or `dvipng` when present.
