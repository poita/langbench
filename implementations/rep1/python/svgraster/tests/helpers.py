from svgraster import render_svg


def pixel(rgb: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    i = (y * width + x) * 3
    return rgb[i], rgb[i + 1], rgb[i + 2]


def render(body: str, w: int, h: int, vb: str | None = None, attrs: str = "") -> bytes:
    vb = vb or f"0 0 {w} {h}"
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" {attrs}>{body}</svg>'
    return render_svg(svg, w, h)
