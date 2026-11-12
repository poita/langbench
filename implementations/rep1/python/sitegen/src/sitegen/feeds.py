"""Writers for ``feed.xml`` (Atom 1.0) and ``sitemap.xml``."""

from __future__ import annotations

from .model import SiteModel, index_url

_EPOCH = "1970-01-01T00:00:00Z"


def xml_text(text: str) -> str:
    """Escape *text* for element content: ``&``, ``<`` and ``>``."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def xml_attr(text: str) -> str:
    """Escape *text* for a double-quoted attribute value."""
    return xml_text(text).replace('"', "&quot;")


def render_feed(model: SiteModel) -> str:
    """The Atom feed holding the newest ``posts_per_page`` posts."""
    base = model.base_url
    entries = model.posts[: model.posts_per_page]
    updated = entries[0]["date"] + "T00:00:00Z" if entries else _EPOCH
    out = [
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<feed xmlns="http://www.w3.org/2005/Atom">\n',
        f"  <title>{xml_text(model.site['title'])}</title>\n",
        f"  <id>{xml_text(base + '/')}</id>\n",
        f"  <updated>{updated}</updated>\n",
        f'  <link href="{xml_attr(base + "/")}" rel="alternate"/>\n',
        f'  <link href="{xml_attr(base + "/feed.xml")}" rel="self"/>\n',
        "  <author>\n",
        f"    <name>{xml_text(model.site['author'])}</name>\n",
        "  </author>\n",
    ]
    for post in entries:
        permalink = post["permalink"]
        out.append("  <entry>\n")
        out.append(f"    <title>{xml_text(post['title'])}</title>\n")
        out.append(f"    <id>{xml_text(permalink)}</id>\n")
        out.append(f"    <updated>{post['date']}T00:00:00Z</updated>\n")
        out.append(f'    <link href="{xml_attr(permalink)}" rel="alternate"/>\n')
        out.append(f'    <content type="html">{xml_text(post["content"])}</content>\n')
        out.append("  </entry>\n")
    out.append("</feed>\n")
    return "".join(out)


def render_sitemap(model: SiteModel) -> str:
    """The sitemap: index pages, posts, pages, the tag index and tags."""
    base = model.base_url
    out = [
        '<?xml version="1.0" encoding="utf-8"?>\n',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n',
    ]

    def add(url: str, lastmod: str | None = None) -> None:
        out.append(f"  <url>\n    <loc>{xml_text(base + url)}</loc>\n")
        if lastmod is not None:
            out.append(f"    <lastmod>{lastmod}</lastmod>\n")
        out.append("  </url>\n")

    for number in range(1, model.total_pages + 1):
        add(index_url(number))
    for post in model.posts:
        add(post["url"], post["date"])
    for page in model.pages:
        add(page["url"])
    add("/tags/")
    for tag in model.tags:
        add(tag["url"])
    out.append("</urlset>\n")
    return "".join(out)
