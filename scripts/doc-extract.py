"""doc-extract.py — Extract documented source code for LaTeX documentation.

Usage:
  python3 scripts/doc-extract.py FILE1 LANG1 [FILE2 LANG2 ...] -o OUTPUT

Reads source files and extracts documentation blocks marked with
language-specific delimiters:

  Lua (--):    --[doc] ... --[/doc]
  Python (#):  #[doc] ... #[/doc]
  LaTeX (%):   %[doc] ... %[/doc]

Lines inside a doc block (after stripping the comment prefix) are passed
through as LaTeX content.  Lines outside doc blocks are wrapped in a
\\begin{minted}[linenos,breaklines,breakautoindent=false]{LANG}
... \\end{minted} environment.

Each input file gets a \\section*{filename} heading in the output.
"""

import argparse
import os
import sys


COMMENT_CHAR = {
    "lua": "--",
    "python": "#",
    "latex": "%",
}

LANGUAGE_ALIASES = {
    "lua": "lua",
    "py": "python",
    "python": "python",
    "sty": "latex",
    "latex": "latex",
    "cls": "latex",
}

MINTED_OPTS = "linenos,breaklines,breakautoindent=false"

MINTED_OPTS_FMT = "linenos,breaklines,breakautoindent=false,firstnumber={}"


import re


def _escape_underscores(text: str) -> str:
    """Escape underscores to \\_ except inside LaTeX constructs
    that protect them (\\texttt, \\verb, \\mintinline) or inside
    math mode ($...$).
    """
    result: list[str] = []
    i = 0
    in_math = False
    while i < len(text):
        # Toggle math mode on bare $ (not escaped \$)
        if text[i] == "$" and (i == 0 or text[i - 1] != "\\"):
            in_math = not in_math
            result.append(text[i])
            i += 1
            continue
        # Check for \texttt{...}
        m = re.match(r"\\texttt(\{[^}]*\})", text[i:])
        if m:
            result.append(m.group(0))
            i += m.end()
            continue
        # Check for \verbX...X
        m = re.match(r"\\verb(.)", text[i:])
        if m:
            delim = m.group(1)
            end = text.find(delim, i + m.end())
            if end != -1:
                result.append(text[i : end + 1])
                i = end + 1
                continue
        # Check for \mintinline{lang}|...|
        m = re.match(r"\\mintinline\{[^}]*\}(.)", text[i:])
        if m:
            delim = m.group(1)
            end = text.find(delim, i + m.end())
            if end != -1:
                result.append(text[i : end + 1])
                i = end + 1
                continue
        # Normal character
        if text[i] == "_" and not in_math:
            result.append("\\_")
        else:
            result.append(text[i])
        i += 1
    return "".join(result)


def convert_line(line: str, cc: str) -> str:
    """Strip comment prefix from a doc line, preserving indentation."""
    line = line.rstrip("\n")
    idx = line.find(cc)
    if idx == -1:
        return line
    rest = line[idx + len(cc):]
    if rest.startswith(" "):
        rest = rest[1:]
    rest = _escape_underscores(rest)
    return rest


def extract_file(path: str, lang: str) -> str:
    cc = COMMENT_CHAR.get(lang, "%")
    doc_open = f"{cc}[doc]"
    doc_close = f"{cc}[/doc]"

    with open(path, encoding="utf-8") as f:
        src_lines = f.readlines()

    out_parts: list[str] = []
    in_doc = False
    code_buf: list[str] = []
    code_start = 1

    def flush_code():
        nonlocal code_start
        if not code_buf:
            return
        content = "".join(code_buf).strip("\n")
        if not content:
            code_buf.clear()
            return
        opts = MINTED_OPTS_FMT.format(code_start)
        out_parts.append(f"\\begin{{minted}}[{opts}]{{{lang}}}")
        out_parts.append(content)
        out_parts.append("\\end{minted}")
        code_buf.clear()

    for linenum, line in enumerate(src_lines, start=1):
        stripped = line.strip()

        if stripped == doc_open:
            flush_code()
            in_doc = True
            code_start = linenum + 1
            continue

        if stripped == doc_close:
            in_doc = False
            code_start = linenum + 1
            continue

        if in_doc:
            out_parts.append(convert_line(line, cc))
        else:
            code_buf.append(line)

    flush_code()
    return "\n".join(out_parts)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract documented source blocks for LaTeX inclusion."
    )
    parser.add_argument("files", nargs="+", help="File paths and languages alternating")
    parser.add_argument("-o", "--output", required=True, help="Output .tex file path")
    args = parser.parse_args()

    pairs: list[tuple[str, str]] = []
    i = 0
    files = args.files
    while i < len(files):
        path = files[i]
        if i + 1 >= len(files):
            print(f"error: missing language for file '{path}'", file=sys.stderr)
            return 1
        lang_raw = files[i + 1].lower()
        lang = LANGUAGE_ALIASES.get(lang_raw, lang_raw)
        if lang not in COMMENT_CHAR:
            print(
                f"error: unknown language '{lang_raw}' for file '{path}'",
                file=sys.stderr,
            )
            return 1
        pairs.append((path, lang))
        i += 2

    sections: list[str] = []
    for path, lang in pairs:
        fname = os.path.basename(path)
        content = extract_file(path, lang).strip()
        sections.append(f"\\section*{{{fname}}}\n\n{content}")

    output = "\n\n".join(sections) + "\n"

    with open(args.output, "w", encoding="utf-8") as f:
        f.write(output)

    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
