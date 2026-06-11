"""Unit tests for contour tracing."""
import os
import tempfile

import numpy as np
from PIL import Image, ImageDraw

from wrapgraphics import load_alpha, threshold, dilate, trace_contour, write_lua


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


def test_dilate():
    img = _make_circle_image()
    alpha = img.split()[-1]
    mask = threshold(alpha, 0.5)
    original_white = sum(1 for y in range(32) for x in range(32) if mask.getpixel((x, y)) > 127)  # type: ignore[operator]
    dilated = dilate(mask, 3)
    dilated_white = sum(1 for y in range(32) for x in range(32) if dilated.getpixel((x, y)) > 127)  # type: ignore[operator]
    assert dilated_white > original_white


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


def test_write_lua(tmp_path):
    pts = [(10.0, 20.0), (30.0, 40.0), (50.0, 60.0)]
    out = tmp_path / "test.lua"
    write_lua(pts, str(out), img_width=100, img_height=200, dpi=72.0)
    text = out.read_text()
    assert "return {" in text
    assert "width = 100" in text
    assert "height = 200" in text
    assert "dpi = 72.0" in text
    assert "contour" in text
    assert "{10.0, 20.0}," in text
    assert "{30.0, 40.0}," in text
    # Verify it parses as valid Lua
    import lupa  # type: ignore[import-untyped]
    from lupa import LuaRuntime  # type: ignore[import-untyped]
    lua = LuaRuntime(unpack_returned_tuples=True)
    result = lua.execute(out.read_text())
    assert result is not None
    assert result["width"] == 100  # type: ignore[index]
    assert result["height"] == 200  # type: ignore[index]
    assert result["dpi"] == 72.0  # type: ignore[index]
    assert len(result["contour"]) == 3  # type: ignore[index]
