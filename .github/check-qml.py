#!/usr/bin/env python3
"""Check two QML invariants that qmllint cannot express.

Both were security findings, and both are the kind a later change reintroduces
by writing ordinary-looking code. A grep is not elegant, but it is the only
thing here that reads the next author's patch.
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors = []


def block(lines, start, span=14):
    return "\n".join(lines[start:start + span])


def element(text, open_index):
    """The source of one QML element, from its `{` to the brace that closes it.

    A fixed window of lines is not enough: it runs past the element and finds a
    neighbour's properties, which is a false pass on exactly the check that
    matters.
    """
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_index:i + 1]
    return text[open_index:]


# A Text without an explicit format is Text.AutoText, which renders anything
# tag-shaped as rich text. Hostnames and error messages reach these from the
# network.
for path in ("Panel.qml", "Service.qml", "ControldIcon.qml"):
    text = (ROOT / path).read_text()
    for m in re.finditer(r"^[ \t]*(?:component \w+: )?Text\s*\{", text, re.MULTILINE):
        open_index = text.index("{", m.start())
        if "textFormat" not in element(text, open_index):
            line = text.count("\n", 0, m.start()) + 1
            errors.append(f"{path}:{line}: Text without textFormat; "
                          f"network data renders as rich text under AutoText")

# Every process must be size-bounded, because StdioCollector holds a whole
# stream and the panel runs inside the shell process.
lines = (ROOT / "Service.qml").read_text().split("\n")
for i, line in enumerate(lines):
    m = re.match(r"\s*(?:\w+\.)?command\s*[:=]\s*(.+)$", line)
    if not m:
        continue
    rhs = m.group(1).strip()
    if rhs in ("[]", "[]  // set when the command is built"):
        continue
    if "bounded(" not in block(lines, i, 3) and "cdctl(" not in block(lines, i, 3):
        errors.append(f"Service.qml:{i + 1}: command not wrapped in bounded() or cdctl(); "
                      f"its output would be retained whole")

if errors:
    for line in errors:
        print(f"qml: {line}", file=sys.stderr)
    sys.exit(1)

print("qml ok: every Text states its format, every command is bounded")
