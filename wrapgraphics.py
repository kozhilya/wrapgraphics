"""wrapgraphics.py — CLI entry point for contour tracing.

Reads an image, extracts the alpha channel, thresholds it, traces the
outer contour with Moore-Neighbor boundary following, simplifies (RDP),
smooths, offsets outward by N pixels (padding), rasterises the offset
contour as a filled polygon and re-traces the outer boundary (removes
self-intersections / swirls), then writes an SVG file.
"""

import argparse
import math
import os
import sys
import traceback

from PIL import Image, UnidentifiedImageError

Point = tuple[float, float]


#[doc]
# \texttt{wrapgraphics.py} --- Python CLI for contour tracing.
#
# This script is the Python backend of the \textsf{wrapgraphics}
# package.  It is called by Lua\LaTeX{} via shell-escape
# (\texttt{os.execute}) and produces an SVG file containing the
# traced contour.
#
# \subsection*{Pipeline}
# \begin{enumerate}
#   \item Load the image, extract the alpha channel.
#   \item Threshold the alpha at a given level (0--1).
#   \item Dilate the binary mask by \texttt{N} pixels (padding) using
#         an integral-image method for \texttt{O(n)} performance.
#   \item Trace the outer contour with the Moore--Neighbor boundary
#         following algorithm.
#   \item Simplify with Ramer--Douglas--Peucker (\texttt{epsilon}).
#   \item Optionally smooth with a Gaussian kernel.
#   \item Write the result as an SVG with embedded image and contour
#         path, plus metadata attributes (DPI, threshold, padding,
#         smooth, invert).
# \end{enumerate}
#[/doc]



#[doc]
# \subsection*{\texttt{load\_alpha}}
# Opens the image and returns the alpha channel as a grayscale
# \texttt{PIL.Image}.  The image is converted to RGBA first so the
# alpha channel is guaranteed to exist.
#[/doc]
def load_alpha(image_path: str) -> Image.Image:
    img = Image.open(image_path).convert("RGBA")
    return img.split()[-1]


#[doc]
# \subsection*{\texttt{threshold}}
# Converts the alpha channel to a binary mask.  Pixels with an alpha
# value greater or equal to \texttt{level * 255} are considered opaque.
#[/doc]
def threshold(alpha: Image.Image, level: float) -> Image.Image:
    threshold_val = int(level * 255)
    return alpha.point(lambda p: 255 if p >= threshold_val else 0)  # type: ignore[return-value]


#[doc]
# \subsection*{\texttt{dilate\_fast}}
# Binary dilation by \texttt{N} pixels using an integral-image
# (summed-area table) approach.  Each pixel is set to white if any
# pixel within a \texttt{(2N+1) x (2N+1)} window in the original
# mask is white.
#
# This is ``fat'' dilation (not morphological): it is equivalent to
# a MAX filter, which acts like dilation on a binary image.  The
# integral image gives \texttt{O(n)} performance regardless of the
# padding size.
#
# Requires NumPy for the integral-image computation.
#[/doc]
def dilate_fast(mask: Image.Image, padding: int) -> Image.Image:
    """Binary dilation via integral image (O(n), fast even for large padding)."""
    if padding <= 0:
        return mask
    import numpy as np
    arr = np.array(mask, dtype=np.uint8)
    bins = (arr > 127).astype(np.int64)
    h_img, w_img = bins.shape
    integral = np.pad(bins.cumsum(axis=0).cumsum(axis=1), (1, 0), mode="constant")[:, :]
    y_idx = np.arange(h_img)[:, None]
    x_idx = np.arange(w_img)[None, :]
    y1 = np.maximum(0, y_idx - padding)
    y2 = np.minimum(h_img, y_idx + padding + 1)
    x1 = np.maximum(0, x_idx - padding)
    x2 = np.minimum(w_img, x_idx + padding + 1)
    s = integral[y2, x2] - integral[y1, x2] - integral[y2, x1] + integral[y1, x1]
    return Image.fromarray((s > 0).astype(np.uint8) * 255, mode="L")


#[doc]
# \subsection*{\texttt{smooth\_contour}}
# Applies Gaussian smoothing to the contour point list.  Each point is
# replaced by a weighted average of its neighbours within a
# \texttt{2*radius+1} window.  The circular nature of the contour is
# preserved by wrapping indices modulo the list length.
#[/doc]
def smooth_contour(points: list[Point], sigma: float) -> list[Point]:
    if sigma <= 0 or len(points) < 3:
        return points
    radius = max(1, round(sigma * 2))
    kernel_size = radius * 2 + 1
    kernel = [math.exp(-((i - radius) ** 2) / (2 * sigma * sigma)) for i in range(kernel_size)]
    ksum = sum(kernel)
    kernel = [w / ksum for w in kernel]
    n = len(points)
    result = []
    for i in range(n):
        sx, sy = 0.0, 0.0
        for j, kw in enumerate(kernel):
            idx = (i + j - radius) % n
            sx += points[idx][0] * kw
            sy += points[idx][1] * kw
        result.append((sx, sy))
    return result


#[doc]
# \subsection*{\texttt{trace\_contour}}
# The core contour-tracing function.  It implements the Moore--Neighbor
# boundary following algorithm:
#
# \begin{enumerate}
#   \item Find the first white (opaque) pixel via \texttt{\_find\_start}.
#   \item Walk the boundary by checking the 8 neighbours in clockwise
#         order, starting from the previous neighbour direction.
#   \item Stop when we return to the start pixel.
# \end{enumerate}
#
# The resulting contour is optionally simplified with the
# Ramer--Douglas--Peucker algorithm.
#[/doc]
def trace_contour(
    binary: Image.Image,
    simplify: bool = True,
    epsilon: float = 1.0,
) -> list[Point]:
    pixels = binary.load()
    w, h = binary.size

    start = _find_start(pixels, w, h)
    if start is None:
        return []

    contour = []
    current = start
    prev = (start[0] - 1, start[1])
    second = None

    moore = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]

    while True:
        contour.append((float(current[0]), float(current[1])))

        if len(contour) == 2:
            second = current

        dx = prev[0] - current[0]
        dy = prev[1] - current[1]
        try:
            start_idx = moore.index((dx, dy))
        except ValueError:
            break

        found = False
        for i in range(8):
            idx = (start_idx + 1 + i) % 8
            nx = current[0] + moore[idx][0]
            ny = current[1] + moore[idx][1]
            if 0 <= nx < w and 0 <= ny < h and pixels[nx, ny] > 127:  # type: ignore[index,operator]
                prev = current
                current = (nx, ny)
                found = True
                break

        if not found:
            break

        if current == start and second is not None:
            break

    if simplify:
        return _simplify(contour, epsilon)
    return contour


#[doc]
# \subsection*{\texttt{\_find\_start}}
# Scans the binary image row-by-row and returns the coordinates of the
# first white (opaque) pixel.  Returns \texttt{None} for an empty mask.
#[/doc]
def _find_start(pixels, w, h) -> tuple[int, int] | None:
    for y in range(h):
        for x in range(w):
            if pixels[x, y] > 127:
                return (x, y)
    return None


#[doc]
# \subsection*{\texttt{\_simplify} (Ramer--Douglas--Peucker)}
# Reduces the number of contour points while preserving the overall
# shape.  The algorithm recursively subdivides the polyline: if a point
# is farther than \texttt{epsilon} from the line segment connecting the
# endpoints, it is kept; otherwise it is discarded.
#
# The recursion splits the contour at the furthest point, so sharp
# corners are retained and straight sections are simplified.
#[/doc]
def _simplify(points: list[Point], epsilon: float = 1.0) -> list[Point]:
    if len(points) <= 3:
        return points

    def _perp_dist(p: Point, a: Point, b: Point) -> float:
        if a == b:
            return math.hypot(p[0] - a[0], p[1] - a[1])
        num = abs((b[1] - a[1]) * p[0] - (b[0] - a[0]) * p[1] + b[0] * a[1] - b[1] * a[0])
        den = math.hypot(b[0] - a[0], b[1] - a[1])
        return num / den

    def _rdp(segment: list[Point]) -> list[Point]:
        if len(segment) <= 2:
            return segment
        dmax = -1.0
        idx = -1
        for i in range(1, len(segment) - 1):
            d = _perp_dist(segment[i], segment[0], segment[-1])
            if d > dmax:
                dmax = d
                idx = i
        if dmax > epsilon:
            left = _rdp(segment[: idx + 1])
            right = _rdp(segment[idx:])
            return left[:-1] + right
        return [segment[0], segment[-1]]

    return _rdp(points)


#[doc]
# \subsection*{\texttt{write\_svg}}
# Writes the contour as an SVG file.  The SVG contains:
# \begin{itemize}
#   \item The original image embedded via \texttt{<image>}.
#   \item The contour as a \texttt{<path>} with named colours.
#   \item Metadata attributes (\texttt{wg-dpi}, \texttt{wg-threshold},
#         \texttt{wg-padding}, \texttt{wg-smooth}, \texttt{wg-invert})
#         used by Lua to detect cache hits.
# \end{itemize}
#[/doc]
def write_svg(
    points: list[Point],
    path: str,
    img_path: str,
    img_width: int,
    img_height: int,
    dpi: float,
    threshold: float = 0.5,
    padding: int = 5,
    smooth: float = 0.0,
    invert: bool = False,
) -> None:
    img_rel = os.path.basename(img_path)
    with open(path, "w") as f:
        f.write(
            '<svg xmlns="http://www.w3.org/2000/svg"'
            f' width="{img_width}" height="{img_height}"\n'
        )
        f.write(
            f'     wg-dpi="{dpi:.1f}"'
            f' wg-threshold="{threshold}"'
            f' wg-padding="{padding}"'
            f' wg-smooth="{smooth:g}"'
            f' wg-invert="{"1" if invert else "0"}">\n'
        )
        f.write(
            f'  <image href="{img_rel}"'
            f' width="{img_width}" height="{img_height}"/>\n'
        )
        f.write('  <path d="')
        if points:
            f.write(f"M {points[0][0]:.1f} {points[0][1]:.1f}")
            for x, y in points[1:]:
                f.write(f" L {x:.1f} {y:.1f}")
            f.write(" Z")
        f.write('" fill="none" stroke="#f00" stroke-width="2"/>\n')
        f.write("</svg>\n")


#[doc]
# \subsection*{CLI entry points}
# \texttt{parse\_args} defines the command-line interface using
# \texttt{argparse}.  The \texttt{main} function orchestrates the full
# pipeline: load, threshold, dilate, trace, smooth, and write SVG.
#
# The \texttt{main} function is also the public Python API --- other
# scripts can call \texttt{wrapgraphics.main(["--input", ...])} and
# handle the integer return code.
#[/doc]
def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Trace alpha contour of an image.")
    parser.add_argument("--input", "-i", required=True, help="Input image path")
    parser.add_argument("--output", "-o", required=True, help="Output -shape.svg file")
    parser.add_argument(
        "--threshold", "-t", type=float, default=0.5,
        help="Alpha threshold (0-1); values >= threshold are opaque",
    )
    parser.add_argument(
        "--padding", "-p", type=int, default=5,
        help="Contour offset in pixels (clearance from image edge)",
    )
    parser.add_argument(
        "--smooth", type=float, default=0.0,
        help="Gaussian smoothing sigma in pixels applied after dilation trace (default: 0 = off)",
    )
    parser.add_argument(
        "--simplify", action=argparse.BooleanOptionalAction, default=True,
        help="Apply Ramer-Douglas-Peucker simplification (default: --simplify)",
    )
    parser.add_argument(
        "--epsilon", type=float, default=3.0,
        help="RDP simplification tolerance in pixels (default: 3.0)",
    )
    parser.add_argument(
        "--invert", action="store_true", default=False,
        help="Invert wrap side: place image on the right, text on the left",
    )
    parser.add_argument(
        "--verbose", action="store_true", default=False,
        help="Print detailed progress information",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
    except SystemExit:
        return 1

    def vprint(*a, **kw):
        if getattr(args, "verbose", False):
            print("[wrapgraphics]", *a, file=sys.stderr, **kw)

    vprint("args:", args)

    if not os.path.isfile(args.input):
        print(f"Error: file not found: {args.input}", file=sys.stderr)
        return 1

    try:
        img = Image.open(args.input)
    except (FileNotFoundError, UnidentifiedImageError, PermissionError) as e:
        print(f"Error: cannot open image '{args.input}': {e}", file=sys.stderr)
        return 1

    dpi = 72.0
    if "dpi" in img.info and img.info["dpi"] is not None:
        dpi = float(img.info["dpi"][0])
    w, h = img.size
    vprint(f"image: {w}x{h}, dpi={dpi:.1f}")

    alpha = load_alpha(args.input)
    vprint(f"alpha channel loaded, mode={alpha.mode}")

    mask = threshold(alpha, args.threshold)
    vprint(f"threshold={args.threshold} applied")

    if args.padding > 0:
        from PIL import ImageOps
        mask = ImageOps.expand(mask, border=args.padding, fill=0)
        vprint(f"padded by {args.padding} px (border)")

    mask = dilate_fast(mask, args.padding)
    vprint(f"dilated by {args.padding} px (integral-image)")

    contour = trace_contour(mask, simplify=args.simplify, epsilon=args.epsilon)
    vprint(f"contour traced: {len(contour)} points (simplify={args.simplify}, epsilon={args.epsilon})")

    if args.padding > 0:
        contour = [(x - args.padding, y - args.padding) for x, y in contour]
        vprint(f"contour translated back by -{args.padding} px")

    if args.smooth > 0:
        contour = smooth_contour(contour, args.smooth)
        vprint(f"smoothed (sigma={args.smooth}) -> {len(contour)} points")

    write_svg(
        contour, args.output, args.input, w, h, dpi,
        threshold=args.threshold, padding=args.padding,
        smooth=args.smooth, invert=args.invert,
    )
    print(f"Wrote {len(contour)} contour points to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
