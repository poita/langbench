"""Running headers and footers."""

from __future__ import annotations

from .context import Env, text_units
from .hlist import BOX, GLUE, BaseStyle
from .output import Page, text_item
from .settings import SLOTS


def substitute(parts: list, values: dict[str, str]) -> str:
    return "".join(p[1] if p[0] == "lit" else values[p[1]] for p in parts)


def render_headers(env: Env, page: Page, values: dict[str, str]) -> None:
    """Add the header and footer items of *page*.

    ``values`` maps the placeholder names to their text for this page.
    """
    s = env.s
    suffix = "_even" if page.value % 2 == 0 else ""
    base = BaseStyle(s.header_font, False, False, s.header_size)
    for slot in SLOTS:
        parts = getattr(s, slot.replace("-", "_") + suffix)
        if not parts:
            continue
        text = substitute(parts, values)
        units = text_units(text)
        if not units:
            continue
        items = env.builder.build(units, base, "justify", False).items[:-3]
        width = sum(it.width for it in items)
        if width == 0 and not any(it.kind == BOX and it.text for it in items):
            continue
        if slot.endswith("left"):
            x = s.body_x
        elif slot.endswith("center"):
            x = s.body_x + (s.body_width - width) // 2
        else:
            x = s.body_x + s.body_width - width
        region = "header" if slot.startswith("header") else "footer"
        y = s.header_baseline if region == "header" else s.footer_baseline
        for it in items:
            if it.kind == BOX and it.text is not None:
                page.items.append(text_item(region, it.face.name, it.size, x, y, it.width, it.text))
            x += it.width
