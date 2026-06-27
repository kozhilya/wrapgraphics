# wrapgraphics

LaTeX package that wraps text around an image based on its alpha channel contour. Uses a Python backend (Pillow) for contour tracing and LuaLaTeX for text reflow computation.

## Requirements

- LuaLaTeX (with `--shell-escape`)
- Python 3 + Pillow

## Installation

Place `wrapgraphics.sty` and `wrapgraphics.py` in the same directory as your document (or in `/usr/share/texmf/tex/latex/wrapgraphics/` for system-wide install).

## Usage

```latex
\documentclass{article}
\usepackage{wrapgraphics}

\begin{document}

\wrapgraphics[threshold=0.5, padding=5, scale=1]{image.png}
% text continues here, wrapping around the image

\end{document}
```

### Options

| Key | Default | Description |
|---|---|---|
| `threshold` | 0.5 | Alpha threshold (0–1). Pixels with alpha ≥ threshold are considered opaque. |
| `padding` | 5 | Extra clearance in pixels between image edge and text. |
| `scale` | 1 | Scale factor passed to `\includegraphics`. |

## How it works

1. `\wrapgraphics` calls `wrapgraphics.py` via `\directlua{os.execute(...)}`
2. Python extracts the alpha channel, applies threshold and dilation (padding), traces the outer contour with Moore-Neighbor boundary following
3. LuaLaTeX reads the contour, computes per-line `\parshape` margins (TODO: full implementation)
4. Image is placed as a overlay; text reflows around it

## Development

```sh
python3 -m pytest tests/
python3 wrapgraphics.py --input image.png --output image.png-shape.svg --threshold 0.5 --padding 5
lualatex --shell-escape demo/demo.tex
```
