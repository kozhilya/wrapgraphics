"""wrapgraphics.py — CLI entry point for contour tracing.

Reads an image, extracts the alpha channel, thresholds it, traces the
outer contour with Moore-Neighbor boundary following, simplifies (RDP),
smooths, offsets outward by N pixels (padding), rasterises the offset
contour as a filled polygon and re-traces the outer boundary (removes
self-intersections / swirls), then writes an SVG file.

Zero external dependencies — only Python stdlib (struct, zlib).
"""

import argparse
import math
import os
import struct
import sys
import zlib

Point = tuple[float, float]


#[doc]
# \texttt{wrapgraphics.py} --- Python CLI for contour tracing.
#
# This script is the Python backend of the \textsf{wrapgraphics}
# package.  It is called by Lua\LaTeX{} via shell-escape
# (\texttt{os.execute}) and produces an SVG file containing the
# traced contour.
#
# \subsubsection{Pipeline}
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


PNG_SIG = b"\x89PNG\r\n\x1a\n"


#[doc]
# \subsubsection{PNG helper: \texttt{\_read\_png\_rgba}}
#
# Parses a PNG file using only \texttt{struct} and \texttt{zlib} from
# the standard library.  Returns \texttt{(width, height, flat\_rgba)}
# where \texttt{flat\_rgba} is a \texttt{bytearray} of RGBA pixel
# data in row-major order (4 bytes per pixel).
#
# Handles colour types 0 (Grayscale), 2 (RGB), 4 (Grayscale+Alpha),
# 6 (RGBA) with bit depth 8.  For types without alpha, fully opaque
# (255) is used.  Indexed colour (type 3) raises an error asking the
# user to convert to RGBA PNG.
#[/doc]
def _read_png_rgba(path: str) -> tuple[int, int, bytearray]:
    with open(path, "rb") as f:
        sig = f.read(8)
        if sig != PNG_SIG:
            raise ValueError(f"Not a valid PNG file: {path}")

        chunks: list[tuple[bytes, bytes]] = []
        while True:
            raw = f.read(4)
            if len(raw) < 4:
                break
            length = struct.unpack(">I", raw)[0]
            chunk_type = f.read(4)
            data = f.read(length) if length > 0 else b""
            crc = f.read(4)
            chunks.append((chunk_type, data))
            if chunk_type == b"IEND":
                break

    ihdr_data = None
    idat_data = b""
    for chunk_type, data in chunks:
        if chunk_type == b"IHDR":
            ihdr_data = data
        elif chunk_type == b"IDAT":
            idat_data += data

    if ihdr_data is None:
        raise ValueError(f"No IHDR chunk in PNG: {path}")

    w, h, bit_depth, color_type = struct.unpack(">IIBB", ihdr_data[:10])
    comp_method, filter_method, interlace = struct.unpack(">BBB", ihdr_data[10:13])

    if comp_method != 0:
        raise ValueError(f"Unsupported PNG compression method: {comp_method}")
    if filter_method != 0:
        raise ValueError(f"Unsupported PNG filter method: {filter_method}")
    if interlace != 0:
        raise ValueError("Interlaced PNG not supported")
    if bit_depth != 8:
        raise ValueError(f"Only 8-bit PNG supported, got bit_depth={bit_depth}")

    if color_type == 3:
        raise ValueError(
            "Indexed-colour PNG not supported. "
            "Please convert to RGBA PNG first (e.g. with ImageMagick: "
            f"convert {os.path.basename(path)} -alpha on PNG32:{os.path.basename(path)}"
        )

    raw = zlib.decompress(idat_data)

    bpp = 1
    if color_type == 0:
        bpp = 1
    elif color_type == 2:
        bpp = 3
    elif color_type == 4:
        bpp = 2
    elif color_type == 6:
        bpp = 4

    stride = 1 + w * bpp
    rows = []
    for y in range(h):
        row_start = y * stride
        filt = raw[row_start]
        row_data = bytearray(raw[row_start + 1 : row_start + stride])
        prev_row = rows[-1] if rows else bytearray(w * bpp)

        if filt == 0:
            pass
        elif filt == 1:
            for i in range(bpp, len(row_data)):
                row_data[i] = (row_data[i] + row_data[i - bpp]) & 0xFF
        elif filt == 2:
            for i in range(len(row_data)):
                row_data[i] = (row_data[i] + prev_row[i]) & 0xFF
        elif filt == 3:
            for i in range(len(row_data)):
                left = row_data[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                row_data[i] = (row_data[i] + (left + up) // 2) & 0xFF
        elif filt == 4:
            for i in range(len(row_data)):
                left = row_data[i - bpp] if i >= bpp else 0
                up = prev_row[i]
                up_left = prev_row[i - bpp] if i >= bpp else 0
                p = left + up - up_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - up_left)
                if pa <= pb and pa <= pc:
                    pred = left
                elif pb <= pc:
                    pred = up
                else:
                    pred = up_left
                row_data[i] = (row_data[i] + pred) & 0xFF
        else:
            raise ValueError(f"Unknown PNG filter type: {filt}")

        rows.append(row_data)

    rgba = bytearray(w * h * 4)
    for y in range(h):
        row = rows[y]
        for x in range(w):
            off = x * bpp
            dst = (y * w + x) * 4
            if color_type == 0:
                g = row[off]
                rgba[dst:dst + 4] = bytes([g, g, g, 255])
            elif color_type == 2:
                rgba[dst:dst + 3] = row[off:off + 3]
                rgba[dst + 3] = 255
            elif color_type == 4:
                g = row[off]
                a = row[off + 1]
                rgba[dst:dst + 4] = bytes([g, g, g, a])
            elif color_type == 6:
                rgba[dst:dst + 4] = row[off:off + 4]
    return w, h, rgba


#[doc]
# \subsubsection{PNG helper: \texttt{\_read\_png\_meta}}
#
# Reads only the header of a PNG file to extract width, height, and
# DPI (from the \texttt{pHYs} chunk, if present).  Returns
# \texttt{(width, height, dpi)}.
#[/doc]
def _read_png_meta(path: str) -> tuple[int, int, float]:
    w, h = 0, 0
    dpi = 72.0
    with open(path, "rb") as f:
        sig = f.read(8)
        if sig != PNG_SIG:
            raise ValueError(f"Not a valid PNG file: {path}")
        while True:
            raw = f.read(4)
            if len(raw) < 4:
                break
            length = struct.unpack(">I", raw)[0]
            chunk_type = f.read(4)
            data = f.read(length) if length > 0 else b""
            crc = f.read(4)

            if chunk_type == b"IHDR":
                w, h = struct.unpack(">II", data[:8])
            elif chunk_type == b"pHYs":
                ppu_x, ppu_y, unit = struct.unpack(">IIB", data)
                if unit == 1 and ppu_x == ppu_y:
                    dpi = ppu_x * 0.0254
            elif chunk_type == b"IEND":
                break
    if w == 0 or h == 0:
        raise ValueError(f"No IHDR chunk found in PNG: {path}")
    return w, h, dpi


#[doc]
# \subsubsection{\texttt{load\_alpha}}
# Opens the image and returns the alpha channel as a flat list of
# pixel values (0--255).  Images without an alpha channel get a
# fully opaque (255) alpha mask.
#
# Returns \texttt{(width, height, flat\_alpha)} where
# \texttt{flat\_alpha} is a \texttt{list[int]} of length w*h.
#[/doc]
def load_alpha(image_path: str) -> tuple[int, int, list[int]]:
    w, h, rgba = _read_png_rgba(image_path)
    alpha = [rgba[(y * w + x) * 4 + 3] for y in range(h) for x in range(w)]
    return w, h, alpha


#[doc]
# \subsubsection{\texttt{threshold}}
# Converts the alpha channel to a binary mask.  Pixels with an alpha
# value greater or equal to \texttt{level * 255} are set to 255
# (opaque); all others are set to 0.
#
# Input and output are flat \texttt{list[int]} of length w*h.
#[/doc]
def threshold(
    pixels: list[int], w: int, h: int, level: float,
) -> list[int]:
    thresh = int(level * 255)
    return [255 if p >= thresh else 0 for p in pixels]


#[doc]
# \subsubsection{\texttt{dilate\_fast}}
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
# Input and output are flat \texttt{list[int]} of length w*h, values
# 0 or 255.  Boundary pixels use a clipped window (implicitly
# treating out-of-bounds positions as black), so no explicit image
# expansion is needed.
#[/doc]
def dilate_fast(pixels: list[int], w: int, h: int, padding: int) -> list[int]:
    if padding <= 0:
        return pixels

    bins = [1 if p > 127 else 0 for p in pixels]
    integral = [0] * ((w + 1) * (h + 1))
    for y in range(h):
        row_sum = 0
        for x in range(w):
            row_sum += bins[y * w + x]
            integral[(y + 1) * (w + 1) + (x + 1)] = integral[y * (w + 1) + (x + 1)] + row_sum

    result = [0] * (w * h)
    for y in range(h):
        y1 = max(0, y - padding)
        y2 = min(h, y + padding + 1)
        for x in range(w):
            x1 = max(0, x - padding)
            x2 = min(w, x + padding + 1)
            s = (integral[y2 * (w + 1) + x2]
                 - integral[y1 * (w + 1) + x2]
                 - integral[y2 * (w + 1) + x1]
                 + integral[y1 * (w + 1) + x1])
            if s > 0:
                result[y * w + x] = 255
    return result


#[doc]
# \subsubsection{\texttt{smooth\_contour}}
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
# \subsubsection{\texttt{trace\_contour}}
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
    pixels: list[int],
    w: int,
    h: int,
    simplify: bool = True,
    epsilon: float = 1.0,
) -> list[Point]:
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
            if 0 <= nx < w and 0 <= ny < h and pixels[ny * w + nx] > 127:
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
# \subsubsection{\texttt{\_find\_start}}
# Scans the binary image row-by-row and returns the coordinates of the
# first white (opaque) pixel.  Returns \texttt{None} for an empty mask.
#[/doc]
def _find_start(pixels: list[int], w: int, h: int) -> tuple[int, int] | None:
    for y in range(h):
        for x in range(w):
            if pixels[y * w + x] > 127:
                return (x, y)
    return None


#[doc]
# \subsubsection{\texttt{\_simplify} (Ramer--Douglas--Peucker)}
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
# \subsubsection{\texttt{write\_svg}}
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
# \subsubsection{CLI entry points}
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
        w, h, dpi = _read_png_meta(args.input)
    except (FileNotFoundError, ValueError, PermissionError) as e:
        print(f"Error: cannot open image '{args.input}': {e}", file=sys.stderr)
        return 1
    vprint(f"image: {w}x{h}, dpi={dpi:.1f}")

    try:
        _, _, alpha = load_alpha(args.input)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    vprint(f"alpha channel loaded ({len(alpha)} px)")

    mask = threshold(alpha, w, h, args.threshold)
    vprint(f"threshold={args.threshold} applied")

    mask = dilate_fast(mask, w, h, args.padding)
    vprint(f"dilated by {args.padding} px (integral-image)")

    contour = trace_contour(mask, w, h, simplify=args.simplify, epsilon=args.epsilon)
    vprint(f"contour traced: {len(contour)} points (simplify={args.simplify}, epsilon={args.epsilon})")

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
