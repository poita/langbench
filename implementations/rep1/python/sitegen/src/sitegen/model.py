"""The content model: ordering, tags, pagination and template values.

:func:`build_model` turns a :class:`~sitegen.source.Source` into a
:class:`SiteModel` whose post, page and tag objects are plain dicts and
lists, exactly the values handed to templates.  Every object is built once
and shared wherever it appears.
"""

from __future__ import annotations

from dataclasses import dataclass

from .content import first_block, long_date, tag_slug
from .markdown import to_html
from .source import Source


@dataclass
class SiteModel:
    """The site as template values (see SPEC.md, "Context variables")."""

    site: dict
    posts: list[dict]  # post objects, canonical order
    pages: list[dict]  # page objects, ordered by slug
    tags: list[dict]  # tag objects (with their posts), ordered by slug
    tag_links: list[dict]  # tag links, ordered by slug
    page_links: list[dict]  # page links, ordered by slug
    posts_per_page: int

    @property
    def base_url(self) -> str:
        return self.site["base_url"]

    @property
    def total_pages(self) -> int:
        return max(1, -(-len(self.posts) // self.posts_per_page))

    def index_posts(self, number: int) -> list[dict]:
        """The posts shown on index page *number* (1-based)."""
        size = self.posts_per_page
        return self.posts[(number - 1) * size : number * size]


def index_url(number: int) -> str:
    """The URL of index page *number*."""
    return "/" if number == 1 else f"/page/{number}/"


def build_model(source: Source) -> SiteModel:
    """Order the content, collect tags and build every template value."""
    base_url = source.site["base_url"]

    # Published posts in canonical order: date descending, slug ascending.
    published = sorted((p for p in source.posts if not p.draft), key=lambda p: p.slug)
    published.sort(key=lambda p: p.date, reverse=True)

    # Tags: one pass over the (post, tag) pairs.
    post_tag_names = [list(dict.fromkeys(p.tags)) for p in published]
    counts: dict[str, int] = {}
    for names in post_tag_names:
        for name in names:
            counts[name] = counts.get(name, 0) + 1
    tag_links: dict[str, dict] = {}
    for name, count in counts.items():
        slug = tag_slug(name)
        tag_links[name] = {"name": name, "slug": slug, "url": f"/tags/{slug}/", "post_count": count}

    # Post links (for older/newer) and post objects.
    post_links = []
    for post in published:
        url = f"/posts/{post.slug}/"
        post_links.append({
            "title": post.title,
            "slug": post.slug,
            "url": url,
            "permalink": base_url + url,
            "date": post.date,
            "date_long": long_date(post.date),
        })
    posts: list[dict] = []
    tag_posts: dict[str, list[dict]] = {name: [] for name in counts}
    for index, post in enumerate(published):
        link = post_links[index]
        obj = {
            "title": link["title"],
            "slug": link["slug"],
            "url": link["url"],
            "permalink": link["permalink"],
            "date": link["date"],
            "date_long": link["date_long"],
            "tags": [tag_links[name] for name in post_tag_names[index]],
            "content": to_html(post.body),
            "excerpt": to_html(first_block(post.body)),
            "older": post_links[index + 1] if index + 1 < len(post_links) else None,
            "newer": post_links[index - 1] if index > 0 else None,
        }
        posts.append(obj)
        for name in post_tag_names[index]:
            tag_posts[name].append(obj)

    # Tag objects, ordered by slug.
    ordered_names = sorted(counts, key=lambda name: tag_links[name]["slug"])
    tags = []
    for name in ordered_names:
        link = tag_links[name]
        tags.append({
            "name": name,
            "slug": link["slug"],
            "url": link["url"],
            "post_count": link["post_count"],
            "posts": tag_posts[name],
        })

    # Pages, ordered by slug.
    published_pages = sorted((p for p in source.pages if not p.draft), key=lambda p: p.slug)
    pages = []
    page_links = []
    for page in published_pages:
        url = f"/{page.slug}/"
        page_links.append({"title": page.title, "slug": page.slug, "url": url})
        pages.append({
            "title": page.title,
            "slug": page.slug,
            "url": url,
            "permalink": base_url + url,
            "content": to_html(page.body),
        })

    return SiteModel(
        site=source.site,
        posts=posts,
        pages=pages,
        tags=tags,
        tag_links=[tag_links[name] for name in ordered_names],
        page_links=page_links,
        posts_per_page=source.site["posts_per_page"],
    )


def build_pagination(model: SiteModel, number: int) -> dict:
    """The ``pagination`` value for index page *number*."""
    total = model.total_pages
    return {
        "number": number,
        "total_pages": total,
        "total_posts": len(model.posts),
        "has_prev": number > 1,
        "has_next": number < total,
        "prev_url": index_url(number - 1) if number > 1 else None,
        "next_url": index_url(number + 1) if number < total else None,
        "links": [
            {"number": i, "url": index_url(i), "current": i == number}
            for i in range(1, total + 1)
        ],
    }
