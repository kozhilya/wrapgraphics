"""wrapgraphics.py — CLI entry point for contour tracing.

Reads an image, extracts the alpha channel, thresholds it, dilates by N
pixels (padding), traces the outer contour with Moore-Neighbor boundary
following, and writes a Lua-returnable table of {x, y} coordinates.
"""

import argparse
import math
import os
import sys

from PIL import Image, ImageFilter

Point = tuple[float, float]


def load_alpha(image_path: str) -> Image.Image:
    img = Image.open(image_path).convert("RGBA")
    return img.split()[-1]


def threshold(alpha: Image.Image, level: float) -> Image.Image:
    threshold_val = int(level * 255)
    return alpha.point(lambda p: 255 if p >= threshold_val else 0)  # type: ignore[return-value]


def dilate(mask: Image.Image, padding: int) -> Image.Image:
    if padding <= 0:
        return mask
    kernel_size = padding * 2 + 1
    return mask.filter(ImageFilter.MaxFilter(kernel_size))


def trace_contour(binary: Image.Image) -> list[Point]:
    pixels = binary.load()
    w, h = binary.size

    start = _find_start(pixels, w, h)
    if start is None:
        return []

    contour = []
    current = start
    prev = (start[0] - 1, start[1])
    second = None

    # Moore neighborhood (clockwise, starting from top-left)
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

    return _simplify(contour)


def _find_start(pixels, w, h) -> tuple[int, int] | None:
    for y in range(h):
        for x in range(w):
            if pixels[x, y] > 127:
                return (x, y)
    return None


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


def write_lua(
    points: list[Point],
    path: str,
    img_width: int,
    img_height: int,
    dpi: float,
) -> None:
    with open(path, "w") as f:
        f.write("return {\n")
        f.write(f"  width = {img_width},\n")
        f.write(f"  height = {img_height},\n")
        f.write(f"  dpi = {dpi:.1f},\n")
        f.write("  contour = {\n")
        for x, y in points:
            f.write(f"    {{{x:.1f}, {y:.1f}}},\n")
        f.write("  },\n")
        f.write("}\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Trace alpha contour of an image.")
    parser.add_argument("--input", "-i", required=True, help="Input image path")
    parser.add_argument("--output", "-o", required=True, help="Output .lua shape file")
    parser.add_argument("--threshold", "-t", type=float, default=0.5, help="Alpha threshold (0-1)")
    parser.add_argument("--padding", "-p", type=int, default=5, help="Dilation padding in pixels")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if not os.path.isfile(args.input):
        print(f"Error: file not found: {args.input}", file=sys.stderr)
        return 1

    img = Image.open(args.input)
    dpi = 72.0
    if "dpi" in img.info and img.info["dpi"] is not None:
        dpi = float(img.info["dpi"][0])
    w, h = img.size

    alpha = load_alpha(args.input)
    mask = threshold(alpha, args.threshold)
    mask = dilate(mask, args.padding)
    contour = trace_contour(mask)
    write_lua(contour, args.output, w, h, dpi)
    print(f"Wrote {len(contour)} contour points to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
