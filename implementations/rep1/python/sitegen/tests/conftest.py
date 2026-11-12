import os

import pytest

SITE_TOML = '''title = "Pond Notes"
base_url = "https://pond.example"
author = "R. Duck"
posts_per_page = 1
'''

FILES = {
    "site.toml": SITE_TOML,
    "content/posts/hello-world.md": (
        '+++\ntitle = "Hello, world"\ndate = "2024-01-10"\ntags = ["Meta"]\n+++\n'
        "The **first** post.\n\nMore text.\n"
    ),
    "content/posts/on-ducks.md": (
        '+++\ntitle = "On Ducks"\ndate = "2024-02-01"\ntags = ["Birds", "Meta"]\nslug = "ducks"\n+++\n'
        "Ducks are *fine*.\n"
    ),
    "content/pages/about.md": '+++\ntitle = "About"\n+++\n# About\n\nNothing here.\n',
    "templates/base.html": (
        "<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n"
        "{% block body %}{% endblock %}\n"
    ),
    "templates/index.html": (
        '{% extends "base.html" %}\n'
        '{% block body %}{% for post in posts %}<h2><a href="{{ post.url }}">{{ post.title }}</a></h2>\n'
        "{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>\n"
        '{% if pagination.has_next %}<a href="{{ pagination.next_url }}">older</a>{% endif %}{% endblock %}\n'
    ),
    "templates/post.html": (
        '{% extends "base.html" %}\n'
        "{% block title %}{{ post.title }} · {{ site.title }}{% endblock %}\n"
        "{% block body %}<article>\n{{ post.content }}</article>\n"
        '<p>{{ post.date_long }}{% for t in post.tags %} <a href="{{ t.url }}">{{ t.name }}</a>{% endfor %}</p>\n'
        '{% if post.older %}<a href="{{ post.older.url }}">{{ post.older.title }}</a>{% endif %}{% endblock %}\n'
    ),
    "templates/page.html": (
        '{% extends "base.html" %}\n{% block title %}{{ page.title }}{% endblock %}\n'
        "{% block body %}{{ page.content }}{% endblock %}\n"
    ),
    "templates/tag.html": (
        '{% extends "base.html" %}\n'
        "{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n"
        "<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}\n"
    ),
    "templates/tags.html": (
        '{% extends "base.html" %}\n'
        '{% block body %}<ul>{% for t in tags %}<li><a href="{{ t.url }}">{{ t.name }}</a> '
        "{{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}\n"
    ),
}

TEMPLATES = {name: text for name, text in FILES.items() if name.startswith("templates/")}


def write_tree(root, files):
    for name, data in files.items():
        path = os.path.join(root, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        mode = "wb" if isinstance(data, bytes) else "w"
        kwargs = {} if isinstance(data, bytes) else {"encoding": "utf-8", "newline": ""}
        with open(path, mode, **kwargs) as handle:
            handle.write(data)


@pytest.fixture
def pond(tmp_path):
    """The worked example of the specification as a source directory."""
    root = tmp_path / "pond"
    write_tree(str(root), {**FILES, "static/robots.txt": "User-agent: *\n"})
    return str(root)


def read_tree(root):
    """Map relative path -> bytes for every file below *root*."""
    result = {}
    for directory, _dirs, names in os.walk(root):
        for name in names:
            path = os.path.join(directory, name)
            with open(path, "rb") as handle:
                result[os.path.relpath(path, root).replace(os.sep, "/")] = handle.read()
    return result
