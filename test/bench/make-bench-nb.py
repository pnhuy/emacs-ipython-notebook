#!/usr/bin/env python3
"""Write the deterministic 300-cell benchmark notebook (nbformat 4.5).

Usage: make-bench-nb.py OUT.ipynb

180 code cells and 120 markdown cells (every fifth cell is markdown,
plus every fifth of the rest).  Code outputs mix stream text,
execute_result text/plain and 20 display_data image/png outputs (a
400x300 solid-colour PNG built with zlib + struct).  Markdown cells
hold headings, lists and a table.  Standard library only; the same
file is produced on every run.
"""

import base64
import json
import struct
import sys
import zlib

N_CELLS = 300
N_MARKDOWN = 120
N_IMAGES = 20
WIDTH, HEIGHT = 400, 300


def png(rgb):
    """Return a WIDTHxHEIGHT PNG filled with the (r, g, b) colour RGB."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    row = b"\x00" + bytes(rgb) * WIDTH  # filter type 0, then pixels
    raw = row * HEIGHT
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def markdown_cell(i):
    source = (f"## Section {i}\n"
              "\n"
              f"Notes for step {i}: *emphasis*, **bold** and `code`.\n"
              "\n"
              "- first item\n"
              "- second item\n"
              "  - nested item\n"
              "\n"
              "| name | value |\n"
              "|------|-------|\n"
              f"| a    | {i}   |\n"
              f"| b    | {i * 2} |\n")
    return {"cell_type": "markdown", "id": f"md{i:06d}", "metadata": {},
            "source": source}


def code_cell(i, k, image_index):
    """Code cell I (the K-th code cell); IMAGE_INDEX is set for image cells."""
    source = (f"x{i} = {i}\n"
              f"for j in range(3):\n"
              f"    print(x{i} + j)\n"
              f"x{i} * 2")
    outputs = [
        {"output_type": "stream", "name": "stdout",
         "text": "".join(f"{i + j}\n" for j in range(3))},
        {"output_type": "execute_result", "execution_count": k + 1,
         "data": {"text/plain": str(i * 2)}, "metadata": {}},
    ]
    if image_index is not None:
        shade = (37 * image_index) % 256
        outputs.append({
            "output_type": "display_data",
            "data": {"image/png": base64.b64encode(png((shade, 128, 255 - shade))).decode("ascii"),
                     "text/plain": "<Figure size 400x300 with 1 Axes>"},
            "metadata": {}})
    return {"cell_type": "code", "id": f"code{i:06d}", "metadata": {},
            "execution_count": k + 1, "source": source, "outputs": outputs}


def notebook():
    # Markdown at a fixed stride gives exactly N_MARKDOWN of N_CELLS.
    markdown_at = {round(j * N_CELLS / N_MARKDOWN) for j in range(N_MARKDOWN)}
    n_code = N_CELLS - N_MARKDOWN
    image_every = n_code // N_IMAGES
    cells, k = [], 0
    for i in range(N_CELLS):
        if i in markdown_at:
            cells.append(markdown_cell(i))
        else:
            image = k // image_every if k % image_every == 0 and k // image_every < N_IMAGES else None
            cells.append(code_cell(i, k, image))
            k += 1
    return {"nbformat": 4, "nbformat_minor": 5,
            "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3",
                                        "language": "python"},
                         "language_info": {"name": "python"}},
            "cells": cells}


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    nb = notebook()
    counts = {}
    for c in nb["cells"]:
        counts[c["cell_type"]] = counts.get(c["cell_type"], 0) + 1
    assert counts == {"code": N_CELLS - N_MARKDOWN, "markdown": N_MARKDOWN}, counts
    with open(argv[1], "w", encoding="utf-8") as f:
        json.dump(nb, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
