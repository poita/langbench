"""The document renderer: tree walk, property inheritance and painting."""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import colors
from .path import Path, ellipse_path, flatten, line_path, parse_path_data, poly_path, rect_path
from .raster import Canvas, encode_ppm, rasterize
from .stroke import stroke_polygons
from .transform import IDENTITY, Matrix, apply, multiply, parse_transform, translate
from .values import parse_length, parse_number_list, parse_opacity, parse_style
from .xmlparse import Element, XMLError, parse_xml

__all__ = ["render_svg", "render_to_canvas", "render_to_ppm"]

MAX_DEPTH = 64
SHAPES = frozenset({"path", "rect", "circle", "ellipse", "line", "polyline", "polygon"})
CONTAINERS = frozenset({"g", "use", "svg"})
TOLERANCE = 0.01  # device pixels

_BLACK = (0, 0, 0)


@dataclass(frozen=True)
class Props:
    """Computed values of the inherited painting properties."""

    fill: colors.Color = _BLACK
    fill_opacity: float = 1.0
    fill_rule: str = "nonzero"
    stroke: colors.Color = colors.NONE
    stroke_width: float = 1.0
    linecap: str = "butt"
    linejoin: str = "miter"
    miterlimit: float = 4.0
    stroke_opacity: float = 1.0
    color: tuple[int, int, int] = _BLACK


def _style_of(el: Element) -> dict[str, str]:
    if el.style is None:
        el.style = parse_style(el.attrs.get("style"))
    return el.style


def _raw(el: Element, name: str) -> str | None:
    """The value of *name* from ``style``, else the attribute, else ``None``."""
    v = _style_of(el).get(name)
    if v is None:
        v = el.attrs.get(name)
    return v


def _enum(value: str | None, allowed: tuple[str, ...], default: str, inherited: str) -> str:
    if value is None:
        return inherited
    return value if value in allowed else default


def compute_props(el: Element, parent: Props) -> Props:
    """Compute the inherited properties of *el* from those of its parent."""
    changes: dict[str, object] = {}
    v = _raw(el, "color")
    if v is not None:
        c = colors.parse_color(v)
        if c == colors.CURRENT:
            pass
        elif isinstance(c, tuple):
            changes["color"] = c
        elif c is None or c == colors.NONE:
            changes["color"] = _BLACK
    for name, attr, default in (("fill", "fill", _BLACK), ("stroke", "stroke", colors.NONE)):
        v = _raw(el, attr)
        if v is not None:
            c = colors.parse_color(v)
            changes[name] = default if c is None else c
    for name, attr in (("fill_opacity", "fill-opacity"), ("stroke_opacity", "stroke-opacity")):
        v = _raw(el, attr)
        if v is not None:
            o = parse_opacity(v)
            changes[name] = 1.0 if o is None else o
    v = _raw(el, "fill-rule")
    if v is not None:
        changes["fill_rule"] = _enum(v, ("nonzero", "evenodd"), "nonzero", parent.fill_rule)
    v = _raw(el, "stroke-linecap")
    if v is not None:
        changes["linecap"] = _enum(v, ("butt", "round", "square"), "butt", parent.linecap)
    v = _raw(el, "stroke-linejoin")
    if v is not None:
        changes["linejoin"] = _enum(v, ("miter", "round", "bevel"), "miter", parent.linejoin)
    v = _raw(el, "stroke-width")
    if v is not None:
        w = parse_length(v)
        changes["stroke_width"] = 1.0 if w is None else w
    v = _raw(el, "stroke-miterlimit")
    if v is not None:
        m = parse_length(v)
        changes["miterlimit"] = 4.0 if m is None else m
    if not changes:
        return parent
    return Props(**{**parent.__dict__, **changes})


def _length_attr(el: Element, name: str, default: float = 0.0) -> float:
    v = parse_length(el.attrs.get(name))
    return default if v is None else v


def shape_path(el: Element) -> Path:
    """Convert a shape element to a path (user coordinates)."""
    tag = el.tag
    if tag == "path":
        return parse_path_data(el.attrs.get("d"))
    if tag == "rect":
        rx = parse_length(el.attrs.get("rx"))
        ry = parse_length(el.attrs.get("ry"))
        return rect_path(_length_attr(el, "x"), _length_attr(el, "y"),
                         _length_attr(el, "width"), _length_attr(el, "height"), rx, ry)
    if tag == "circle":
        r = _length_attr(el, "r")
        return ellipse_path(_length_attr(el, "cx"), _length_attr(el, "cy"), r, r)
    if tag == "ellipse":
        return ellipse_path(_length_attr(el, "cx"), _length_attr(el, "cy"),
                            _length_attr(el, "rx"), _length_attr(el, "ry"))
    if tag == "line":
        return line_path(_length_attr(el, "x1"), _length_attr(el, "y1"),
                         _length_attr(el, "x2"), _length_attr(el, "y2"))
    if tag in ("polyline", "polygon"):
        return poly_path(el.attrs.get("points"), tag == "polygon")
    return []


def _resolve(c: colors.Color, props: Props) -> tuple[float, float, float] | None:
    if c == colors.NONE:
        return None
    if c == colors.CURRENT:
        c = props.color
    assert isinstance(c, tuple)
    return c[0] / 255.0, c[1] / 255.0, c[2] / 255.0


class Renderer:
    """Renders one parsed document onto a :class:`Canvas`."""

    def __init__(self, root: Element, width: int, height: int) -> None:
        self.root = root
        self.width = width
        self.height = height
        self.ids: dict[str, Element] = {}
        stack = [root]
        order: list[Element] = []
        while stack:  # document order, iteratively
            el = stack.pop()
            order.append(el)
            stack.extend(reversed(el.children))
        for el in order:
            i = el.attrs.get("id")
            if i is not None and i not in self.ids:
                self.ids[i] = el

    # -- viewport -----------------------------------------------------
    def viewport_matrix(self) -> Matrix:
        a = self.root.attrs
        vx = vy = 0.0
        vw, vh = float(self.width), float(self.height)
        nums = parse_number_list(a.get("viewBox"))
        w = parse_length(a.get("width"))
        h = parse_length(a.get("height"))
        if len(nums) >= 4 and nums[2] > 0 and nums[3] > 0:
            vx, vy, vw, vh = nums[0], nums[1], nums[2], nums[3]
        elif w is not None and h is not None and w > 0 and h > 0:
            vw, vh = w, h
        sx, sy = self.width / vw, self.height / vh
        return (sx, 0.0, 0.0, sy, -vx * sx, -vy * sy)

    # -- tree walk ----------------------------------------------------
    def render(self) -> Canvas:
        canvas = Canvas(self.width, self.height)
        if self.root.tag == "svg":
            self.element(self.root, canvas, self.viewport_matrix(), Props(), 0, True)
        return canvas

    def element(self, el: Element, canvas: Canvas, ctm: Matrix, parent: Props,
                depth: int, is_root: bool = False) -> None:
        if depth > MAX_DEPTH:
            return
        tag = el.tag
        if not (tag in CONTAINERS or tag in SHAPES):
            return
        if tag == "svg" and not is_root:
            return
        if _raw(el, "display") == "none":
            return
        o = parse_opacity(_raw(el, "opacity"))
        opacity = 1.0 if o is None else o
        if opacity == 0.0:
            return
        props = compute_props(el, parent)
        m = ctm if is_root else multiply(ctm, parse_transform(el.attrs.get("transform")))
        target = canvas
        if opacity < 1.0:
            target = Canvas(self.width, self.height)
        if tag in ("g", "svg"):
            for child in el.children:
                self.element(child, target, m, props, depth + 1)
        elif tag == "use":
            self.use(el, target, m, props, depth)
        else:
            self.shape(el, target, m, props)
        if target is not canvas:
            canvas.composite(target, opacity)

    def use(self, el: Element, canvas: Canvas, ctm: Matrix, props: Props, depth: int) -> None:
        href = el.attrs.get("href", "")
        if not href.startswith("#"):
            return
        ref = self.ids.get(href[1:])
        if ref is None or not (ref.tag == "g" or ref.tag in SHAPES):
            return
        m = multiply(ctm, translate(_length_attr(el, "x"), _length_attr(el, "y")))
        self.element(ref, canvas, m, props, depth + 1)

    # -- painting -----------------------------------------------------
    def shape(self, el: Element, canvas: Canvas, ctm: Matrix, props: Props) -> None:
        path = shape_path(el)
        if not path:
            return
        fill = _resolve(props.fill, props)
        if fill is not None and props.fill_opacity > 0 and el.tag != "line":
            polys = [sp.points for sp in flatten(path, ctm, TOLERANCE) if len(sp.points) >= 3]
            if polys:
                runs = rasterize(polys, props.fill_rule == "evenodd", self.width, self.height)
                canvas.paint(runs, fill, props.fill_opacity)
        stroke = _resolve(props.stroke, props)
        if stroke is not None and props.stroke_width > 0 and props.stroke_opacity > 0:
            scale = max(math.hypot(ctm[0], ctm[1]), math.hypot(ctm[2], ctm[3]))
            if scale > 0 and math.isfinite(scale):
                tol = TOLERANCE / scale
                subpaths = flatten(path, None, tol)
                pieces = stroke_polygons(subpaths, props.stroke_width, props.linecap,
                                         props.linejoin, props.miterlimit, tol)
                polys = [[apply(ctm, x, y) for x, y in piece] for piece in pieces]
                if polys:
                    runs = rasterize(polys, False, self.width, self.height)
                    canvas.paint(runs, stroke, props.stroke_opacity)


def render_to_canvas(svg_text: str, width: int, height: int) -> Canvas:
    """Render SVG source text onto a new canvas of the given pixel size."""
    try:
        root = parse_xml(svg_text)
    except XMLError:
        return Canvas(width, height)
    return Renderer(root, width, height).render()


def render_svg(svg_text: str, width: int, height: int) -> bytes:
    """Render SVG source text to packed 8-bit RGB (rows top to bottom)."""
    return render_to_canvas(svg_text, width, height).to_rgb_bytes()


def render_to_ppm(svg_text: str, width: int, height: int) -> bytes:
    """Render SVG source text to a binary PPM (P6) file image."""
    return encode_ppm(width, height, render_svg(svg_text, width, height))
