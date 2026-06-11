"""Generate a sample RGBA image with a circle for testing/demo."""
from PIL import Image, ImageDraw


def generate(width=200, height=200) -> Image.Image:
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx, cy = width // 2, height // 2
    r = min(width, height) // 2 - 10
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(100, 150, 200, 255))
    return img


if __name__ == "__main__":
    import os
    img = generate()
    path = os.path.join(os.path.dirname(__file__) or ".", "sample.png")
    img.save(path)
    print(f"Created {path}")
