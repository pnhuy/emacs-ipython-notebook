#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Huy Pham
#
# audit.sh --- Print a reproducible environment/compatibility audit for EIN.
#
# Usage: sh tools/audit.sh [--user-init]
#
# Makes no network requests.  With --user-init it also loads the
# user's personal Emacs configuration (opt-in) to report which EIN
# library the real configuration resolves.

repo=$(cd "$(dirname "$0")/.." && pwd)

section() { printf '\n## %s\n' "$1"; }

section date
date -u '+%Y-%m-%dT%H:%M:%SZ'

section emacs
emacs --version 2>/dev/null | head -1 || echo "emacs: not found"

section jupyter
if command -v jupyter >/dev/null 2>&1; then
    jupyter --version 2>/dev/null
else
    echo "jupyter: not found"
fi

section python
python3 --version 2>&1
command -v python3 || echo "python3: not found"

section kernelspecs
if command -v jupyter >/dev/null 2>&1; then
    jupyter kernelspec list --json 2>/dev/null
else
    echo "none"
fi

section git
git -C "$repo" rev-parse --abbrev-ref HEAD
git -C "$repo" rev-parse HEAD
printf 'dirty-files: %s\n' "$(git -C "$repo" status --porcelain | wc -l | tr -d ' ')"

section elpa-ein
found=0
for d in "$HOME"/.emacs.d/elpa/ein-*; do
    if [ -d "$d" ]; then echo "$d"; found=1; fi
done
[ "$found" -eq 0 ] && echo "none"

section lisp-elc
n=0
for f in "$repo"/lisp/*.elc; do [ -e "$f" ] && n=$((n + 1)); done
echo "$n"

section latex-tools
for t in latex dvisvgm dvipng; do
    p=$(command -v "$t" 2>/dev/null)
    printf '%s: %s\n' "$t" "${p:-not found}"
done

if [ "$1" = "--user-init" ]; then
    section locate-library-ein
    emacs --batch -l "$HOME/.emacs.d/early-init.el" -l "$HOME/.emacs.d/init.el" \
          --eval '(princ (locate-library "ein"))' 2>/dev/null
    echo
fi
