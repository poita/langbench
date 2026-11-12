"""Formatting of placed items and of the ``layout.txt`` / ``report.txt`` files."""

from __future__ import annotations

from .lines import Stats

REGION_RANK = {"header": 0, "float": 1, "body": 2, "footnote": 3, "footer": 4}

# An output item is a sortable tuple: (region rank, y, x, kind rank, text line).
Item = tuple


def _quote(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def text_item(region: str, face: str, size: int, x: int, y: int, width: int, text: str) -> Item:
    line = f'text {region} {face} {size} {x} {y} {width} "{_quote(text)}"'
    return (REGION_RANK[region], y, x, 0, line)


def rule_item(region: str, x: int, y: int, width: int, thickness: int) -> Item:
    return (REGION_RANK[region], y, x, 1, f"rule {region} {x} {y} {width} {thickness}")


def box_item(region: str, x: int, y: int, width: int, height: int) -> Item:
    return (REGION_RANK[region], y, x, 2, f"box {region} {x} {y} {width} {height}")


class Page:
    """One output page: its label and its (unsorted) items."""

    def __init__(self, label: str, value: int, front: bool) -> None:
        self.label = label
        self.value = value  # the label's numeric value (even/odd decisions)
        self.front = front
        self.items: list[Item] = []
        self.headings: list = []  # headings whose first line is on this page


def render_layout(pages: list[Page], s) -> str:
    out = ["layout 1", f"pages {len(pages)}"]
    for index, page in enumerate(pages, 1):
        out.append(f"page {index} {page.label} {s.page_width} {s.page_height} "
                   f"{s.body_x} {s.body_y} {s.body_width} {s.body_height}")
        for item in sorted(page.items):
            out.append("  " + item[4])
    return "\n".join(out) + "\n"


def render_report(stats: Stats, pages: int, front_pages: int) -> str:
    rows = [
        ("pages", pages),
        ("front-pages", front_pages),
        ("body-pages", pages - front_pages),
        ("lines", stats.lines),
        ("paragraphs", stats.paragraphs),
        ("headings", stats.headings),
        ("tables", stats.tables),
        ("figures", stats.figures),
        ("footnotes", stats.footnotes),
        ("footnote-split-lines", stats.footnote_split_lines),
        ("hyphenated-lines", stats.hyphenated_lines),
        ("overfull-lines", stats.overfull_lines),
        ("emergency-lists", stats.emergency_lists),
        ("total-demerits", stats.total_demerits),
    ]
    return "report 1\n" + "".join(f"{k} {v}\n" for k, v in rows)
