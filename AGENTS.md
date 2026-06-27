# AGENTS.md — wrapgraphics

## Project

LaTeX package + Python backend that wraps text around an image's alpha channel contour.

## Architecture

- **Python** (`wrapgraphics.py`) — reads image, thresholds alpha, dilates by N px, traces contour (Moore-Neighbor), writes `.shape.svg`
- **LuaLaTeX** (`wrapgraphics.sty` + `wrapgraphics.lua`) —
  - `wrapgraphics.sty` — sets up TeX keys/macros, calls `wrapgraphics_run()` via `\directlua`
  - `wrapgraphics.lua` — parsed by Lua directly (no catcode issues), computes `\parshape` from contour, places `\includegraphics`
- Follows the `minted` pattern (LaTeX shell-escapes to Python), but uses LuaLaTeX for the wrapping math instead of a pure TeX approach

## Key insight: Lua code catcode problem

`#` (catcode 6) and `~` (catcode 13 active) are special in TeX and cause errors inside `\directlua{...}` within macro definitions. The fix: put all Lua code in a separate `wrapgraphics.lua` file loaded via `\directlua{dofile("wrapgraphics.lua")}` at package load time. The `.lua` file is read directly by Lua, bypassing all TeX catcode issues.

## Engine

LuaLaTeX **only**. Requires `--shell-escape`.

## Key files

| File | Role |
|---|---|
| `wrapgraphics.py` | CLI entry point. Depends only on `Pillow` |
| `wrapgraphics.sty` | Package: keys, \savebox, shell-escape to Python, calls Lua |
| `wrapgraphics.lua` | Lua: SVG parsing, parshape computation, image placement |
| `demo.tex` | Example document |
| `tests/test_contour.py` | Unit tests for contour tracing |

## Commands

```sh
# Run contour trace standalone
python3 wrapgraphics.py --input image.png --output image.png-shape.svg --threshold 0.5 --padding 5

# Test
python3 -m pytest tests/

# Compile demo
lualatex --shell-escape demo.tex
```

## Important details

- Contour is traced on the **dilated** alpha threshold mask (padding argument), so the text keeps `N` px clearance from the image boundary
- The `-shape.svg` output is an SVG with the image embedded as `<image>`, the contour as a `<path>`, and metadata in `wg-dpi`/`wg-threshold`/`wg-padding` attributes
- Lua parses the SVG with simple string matching (no XML library)
- `\parshape` computation in Lua handles y-flip and unit conversion (pixels → points → scaled points)
- The image is placed with Overlay / `\rlap` so it sits inside the reflowed paragraph
- `\directlua{dofile("wrapgraphics.lua")}` in the .sty loads the Lua module; no catcode hacks needed in the .lua file
- `string.char(37)` is used for `%` in Lua `string.format` because `%` is a comment character in TeX
- Both `wrapgraphics.sty` and `wrapgraphics.lua` must be in a path kpsewhich can find (same directory or texmf tree)
- `verbose` is a package option: `\usepackage[verbose]{wrapgraphics}` — writes `[wrapgraphics]` lines to terminal/log
