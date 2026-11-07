#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Huy Pham
"""Generate the deterministic notebook round-trip corpus.

Usage: python3 -I test/fixtures/make-corpus.py

Writes test/fixtures/roundtrip/*.ipynb, test/fixtures/invalid/*.ipynb
and test/fixtures/roundtrip/manifest.json.  Uses only the standard
library; ids come from a fixed-seed RNG, so reruns are byte-identical.
"""

import json
import os
import random
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
RT = os.path.join(HERE, "roundtrip")
INV = os.path.join(HERE, "invalid")
RNG = random.Random(20261107)

# 1x1 transparent PNG
PNG = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
       "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")

KERNELSPEC = {"display_name": "Python 3", "language": "python", "name": "python3"}
LANGINFO = {"codemirror_mode": {"name": "ipython", "version": 3},
            "file_extension": ".py", "mimetype": "text/x-python",
            "name": "python", "nbconvert_exporter": "python",
            "pygments_lexer": "ipython3", "version": "3.14.9"}


def cid():
    return str(uuid.UUID(int=RNG.getrandbits(128), version=4))[:8]


def md(source, **extra):
    c = {"cell_type": "markdown", "id": cid(), "metadata": {}, "source": source}
    c.update(extra)
    return c


def code(source, outputs=(), count=None, metadata=None, **extra):
    c = {"cell_type": "code", "execution_count": count, "id": cid(),
         "metadata": metadata or {}, "outputs": list(outputs), "source": source}
    c.update(extra)
    return c


def raw(source):
    return {"cell_type": "raw", "id": cid(), "metadata": {}, "source": source}


def nb(cells, metadata=None, minor=5, **top):
    d = {"cells": cells,
         "metadata": metadata if metadata is not None
         else {"kernelspec": KERNELSPEC, "language_info": LANGINFO},
         "nbformat": 4, "nbformat_minor": minor}
    d.update(top)
    return d


def stream(text, name="stdout"):
    return {"name": name, "output_type": "stream", "text": text}


def result(data, count):
    return {"data": data, "execution_count": count, "metadata": {},
            "output_type": "execute_result"}


def display(data, metadata=None):
    return {"data": data, "metadata": metadata or {},
            "output_type": "display_data"}


def corpus():
    c = {}
    c["smoke.ipynb"] = nb(
        [md(["# Smoke\n", "\n", "Some *text*."]),
         code(["import os\n", "print(os.sep)"], [stream("/\n")], 1,
              {"tags": ["keep-tag"]})],
        {"kernelspec": KERNELSPEC, "language_info": LANGINFO,
         "custom_field": {"keep": True}})
    c["attachments.ipynb"] = nb(
        [md(["An image:\n", "![x](attachment:a.png)"],
            attachments={"a.png": {"image/png": PNG}})])
    c["unknown-keys.ipynb"] = nb(
        [code("x = 1", count=None, x_unknown={"k": [1, 2]})],
        x_top="kept")
    nb44 = nb([md("No ids here"), code("1 + 1", [result({"text/plain": "2"}, 1)], 1)],
              minor=4)
    for cell in nb44["cells"]:
        del cell["id"]
    c["nb44-no-ids.ipynb"] = nb44
    short = nb([code("pass")])
    short["cells"][0]["id"] = "a"
    c["short-id.ipynb"] = short
    c["multimime.ipynb"] = nb([code("show()", [display(
        {"text/plain": "<Figure>", "image/png": PNG,
         "text/html": "<b>fig</b>"},
        {"image/png": {"width": 1, "height": 1}})], 3)])
    c["error-output.ipynb"] = nb([code("1/0", [{
        "ename": "ZeroDivisionError", "evalue": "division by zero",
        "output_type": "error",
        "traceback": ["\u001b[31m---------------------------------\u001b[0m",
                      "\u001b[31mZeroDivisionError\u001b[0m: division by zero"]}], 4)])
    c["svg-output.ipynb"] = nb([code("svg", [display({
        "image/svg+xml": ["<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\">",
                          "<script>alert(1)</script><rect width=\"10\" height=\"10\"/></svg>"],
        "text/plain": "<SVG>"})], 5)])
    c["html-table.ipynb"] = nb([code("df", [result({
        "text/html": ["<table border=\"1\" class=\"dataframe\">\n",
                      "<thead><tr><th></th><th>a</th></tr></thead>\n",
                      "<tbody><tr><th>0</th><td>1</td></tr></tbody>\n",
                      "</table>"],
        "text/plain": "   a\n0  1"}, 6)], 6)])
    c["latex-output.ipynb"] = nb([code("Math(...)", [display({
        "text/latex": "$$e^{i\\pi} + 1 = 0$$", "text/plain": "<Math>"})], 7)])
    c["widget-mime.ipynb"] = nb([code("w", [display({
        "application/vnd.jupyter.widget-view+json":
            {"model_id": "abc123", "version_major": 2, "version_minor": 0},
        "text/plain": "IntSlider(value=0)"})], 8)],
        {"kernelspec": KERNELSPEC, "language_info": LANGINFO,
         "widgets": {"application/vnd.jupyter.widget-state+json":
                     {"state": {}, "version_major": 2, "version_minor": 0}}})
    c["raw-cell.ipynb"] = nb([raw("raw \\LaTeX text"), code("pass")])
    c["empty.ipynb"] = nb([])
    c["jupyterlab-style.ipynb"] = nb(
        [md("## Lab"), code("a = 1", count=1,
                            metadata={"collapsed": False, "jupyter": {"source_hidden": False},
                                      "scrolled": True})],
        {"kernelspec": KERNELSPEC, "language_info": LANGINFO,
         "toc-autonumbering": False})
    c["vscode-style.ipynb"] = nb(
        [code("print('vs')", [stream("vs\n")], 1)],
        {"kernelspec": KERNELSPEC, "language_info": LANGINFO,
         "vscode": {"interpreter": {"hash": "0" * 64}}})
    c["nb46-future.ipynb"] = nb([code("pass", x_future=True)], minor=6)
    return c


# Fixtures that nbformat.validate rejects: they carry keys the
# schema forbids (additionalProperties: false) on purpose.  nbformat
# is lenient with a future nbformat_minor, so nb46-future validates.
NOT_VALID = {"unknown-keys.ipynb"}


def dump(path, obj):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")


def main():
    os.makedirs(RT, exist_ok=True)
    os.makedirs(INV, exist_ok=True)
    c = corpus()
    for name, obj in c.items():
        dump(os.path.join(RT, name), obj)
    dump(os.path.join(RT, "manifest.json"),
         {name: {"nbformat_valid": name not in NOT_VALID} for name in sorted(c)})
    with open(os.path.join(RT, "smoke.ipynb"), "rb") as f:
        head = f.read(200)
    with open(os.path.join(INV, "truncated.ipynb"), "wb") as f:
        f.write(head)
    dump(os.path.join(INV, "no-cells.ipynb"),
         {"metadata": {}, "nbformat": 4, "nbformat_minor": 5})
    dump(os.path.join(INV, "cells-not-list.ipynb"),
         {"cells": {}, "metadata": {}, "nbformat": 4, "nbformat_minor": 5})
    dump(os.path.join(INV, "nbformat3.ipynb"),
         {"metadata": {"name": "old"}, "nbformat": 3, "nbformat_minor": 0,
          "worksheets": [{"cells": [{"cell_type": "code", "collapsed": False,
                                     "input": "1", "language": "python",
                                     "metadata": {}, "outputs": [],
                                     "prompt_number": 1}],
                          "metadata": {}}]})


if __name__ == "__main__":
    main()
