# AGENTS.md — wrapgraphics

## Project

LaTeX package + Python backend that wraps text around an image's alpha channel contour.

## Architecture

- **Python** (`wrapgraphics.py`) — reads image, thresholds alpha, dilates by N px, traces contour (Moore-Neighbor), writes `.shape.lua`
- **LuaLaTeX** (`wrapgraphics.sty`) — `\wrapgraphics[keyvals]{image}` calls Python via `os.execute` inside `\directlua`, reads the shape with `dofile`, computes `\parshape` from contour, places `\includegraphics`
- Follows the `minted` pattern (LaTeX shell-escapes to Python), but uses LuaLaTeX for the wrapping math instead of a pure TeX approach

## Engine

LuaLaTeX **only**. Requires `--shell-escape`.

## Key files

| File | Role |
|---|---|
| `wrapgraphics.py` | CLI entry point. Depends only on `Pillow` |
| `wrapgraphics.sty` | Package. Depends on `luatexbase`, `graphicx`, `xkeyval` |
| `demo/demo.tex` | Example document |
| `tests/test_contour.py` | Unit tests for contour tracing |

## Commands

```sh
# Run contour trace standalone
python3 wrapgraphics.py --input image.png --output image.shape.lua --threshold 0.5 --padding 5

# Test
python3 -m pytest tests/

# Compile demo
lualatex --shell-escape demo/demo.tex
```

## Important details

- Contour is traced on the **dilated** alpha threshold mask (padding argument), so the text keeps `N` px clearance from the image boundary
- The `.shape.lua` output is `return {{x,y}, ...}` in pixel coordinates (x=column, y=row from top)
- `\parshape` computation in Lua handles y-flip and unit conversion (pixels → points → scaled points)
- The image is placed with Overlay / `\llap` so it sits inside the reflowed paragraph
