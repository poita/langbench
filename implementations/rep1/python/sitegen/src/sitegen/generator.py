"""Generating the output site."""

from __future__ import annotations

import os

from .feeds import render_feed, render_sitemap
from .model import SiteModel, build_model, build_pagination
from .source import Source, read_source
from .template import Environment


def render_pages(source: Source) -> dict[str, str]:
    """Render every generated file of the site.

    Returns a mapping from output path (relative, ``/``-separated) to file
    contents.  Static files are not included.
    """
    model = build_model(source)
    return render_model(model, Environment(source.templates))


def render_model(model: SiteModel, env: Environment) -> dict[str, str]:
    """Render the generated files for an already built *model*."""
    shared = {"site": model.site, "tags": model.tag_links, "pages": model.page_links}
    files: dict[str, str] = {}

    for number in range(1, model.total_pages + 1):
        context = dict(shared)
        context["posts"] = model.index_posts(number)
        context["pagination"] = build_pagination(model, number)
        path = "index.html" if number == 1 else f"page/{number}/index.html"
        files[path] = env.render("index.html", context)
    for post in model.posts:
        files[f"posts/{post['slug']}/index.html"] = env.render("post.html", {**shared, "post": post})
    for page in model.pages:
        files[f"{page['slug']}/index.html"] = env.render("page.html", {**shared, "page": page})
    files["tags/index.html"] = env.render("tags.html", shared)
    for tag in model.tags:
        context = {**shared, "tag": tag, "posts": tag["posts"]}
        files[f"tags/{tag['slug']}/index.html"] = env.render("tag.html", context)
    files["feed.xml"] = render_feed(model)
    files["sitemap.xml"] = render_sitemap(model)
    return files


def write_files(files: dict[str, str], output: str) -> None:
    """Write rendered text files below *output* (UTF-8, no newline changes)."""
    for relative, text in files.items():
        path = os.path.join(output, *relative.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(text.encode("utf-8"))


def copy_static(static_dir: str, output: str) -> None:
    """Copy every file below *static_dir* to *output*, byte for byte."""
    for directory, _subdirs, names in os.walk(static_dir):
        target_dir = os.path.join(output, os.path.relpath(directory, static_dir))
        for name in names:
            os.makedirs(target_dir, exist_ok=True)
            with open(os.path.join(directory, name), "rb") as src:
                data = src.read()
            with open(os.path.join(target_dir, name), "wb") as dst:
                dst.write(data)


def generate(input_dir: str, output_dir: str) -> None:
    """Generate the site in *input_dir* into *output_dir*.

    The output directory is created if it does not exist.
    """
    source = read_source(input_dir)
    files = render_pages(source)
    os.makedirs(output_dir, exist_ok=True)
    write_files(files, output_dir)
    if source.static_dir is not None:
        copy_static(source.static_dir, output_dir)
