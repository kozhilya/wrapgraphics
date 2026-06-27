"""Unit tests for contour tracing."""
import os
import tempfile

import numpy as np
from PIL import Image, ImageDraw

from wrapgraphics import load_alpha, threshold, trace_contour, offset_contour, write_svg


def _make_circle_image(size=32) -> Image.Image:
    """Create a 32x32 RGBA image with a white circle on transparent bg."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    r = 10
    cx, cy = size // 2, size // 2
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 255))
    return img


def test_load_alpha():
    img = _make_circle_image()
    # Save to temp file and load back
    with tempfile.NamedTemporaryFile(suffix=".png") as f:
        img.save(f.name)
        alpha = load_alpha(f.name)
        assert alpha.mode == "L"
        assert alpha.size == (32, 32)


def test_threshold():
    img = _make_circle_image()
    alpha = img.split()[-1]
    mask = threshold(alpha, 0.5)
    assert mask.mode == "L"
    # The circle center should be white, corners should be black
    assert mask.getpixel((16, 16)) == 255
    assert mask.getpixel((0, 0)) == 0


def test_offset_contour():
    pts = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
    offset = offset_contour(pts, 5)
    assert len(offset) == len(pts)
    # Original square: x in [0,10], y in [0,10]. Offset by 5 outward should
    # expand the bounding box by ~5px on each side (more at corners).
    xs = [p[0] for p in offset]
    ys = [p[1] for p in offset]
    assert min(xs) < -1, f"Expected offset to expand left, got min_x={min(xs)}"
    assert max(xs) > 11, f"Expected offset to expand right, got max_x={max(xs)}"
    assert min(ys) < -1, f"Expected offset to expand up, got min_y={min(ys)}"
    assert max(ys) > 11, f"Expected offset to expand down, got max_y={max(ys)}"


def test_trace_contour():
    img = _make_circle_image()
    alpha = img.split()[-1]
    mask = threshold(alpha, 0.5)
    contour = trace_contour(mask)
    assert len(contour) > 0
    assert len(contour) >= 8, f"Expected at least 8 contour points, got {len(contour)}"


def test_trace_no_alpha():
    """Transparent image should yield empty contour."""
    img = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    alpha = img.split()[-1]
    mask = threshold(alpha, 0.5)
    contour = trace_contour(mask)
    assert contour == []


def test_trace_fully_opaque():
    """Fully opaque image should trace the outer border."""
    img = Image.new("RGBA", (16, 16), (255, 255, 255, 255))
    alpha = img.split()[-1]
    mask = threshold(alpha, 0.5)
    contour = trace_contour(mask)
    assert len(contour) > 0
    # Contour should be at the outer edge
    for x, y in contour:
        assert x >= 0 and x <= 15
        assert y >= 0 and y <= 15


def test_write_svg(tmp_path):
    pts = [(10.0, 20.0), (30.0, 40.0), (50.0, 60.0)]
    img = tmp_path / "test.png"
    out = tmp_path / "test.png-shape.svg"
    write_svg(pts, str(out), str(img), img_width=100, img_height=200, dpi=72.0)
    text = out.read_text()
    assert "<svg" in text
    assert 'xmlns="http://www.w3.org/2000/svg"' in text
    assert 'width="100"' in text
    assert 'height="200"' in text
    assert 'wg-dpi="72.0"' in text
    assert 'wg-smooth="2.0"' in text
    assert "<image" in text
    assert "<path" in text
    assert 'd="M 10.0 20.0 L 30.0 40.0 L 50.0 60.0 Z"' in text
