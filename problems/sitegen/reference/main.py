#!/usr/bin/env python3
"""Reference implementation of the `sitegen` static site generator.

Usage: main.py <input site directory> <output directory>

The Markdown converter and the template engine are the already-validated
reference implementations of the `commonmark` and `template` problems; this
module supplies the TOML subset parser, the content model, the page
rendering and the feed/sitemap/static output.
"""
import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEMS = os.path.normpath(os.path.join(HERE, '..', '..'))


def _load(name, path):
    """Imports a sibling problem's reference implementation under its own name."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


markdown = _load('sitegen_commonmark',
                 os.path.join(PROBLEMS, 'commonmark', 'reference', 'main.py'))
jinja = _load('sitegen_template',
              os.path.join(PROBLEMS, 'template', 'reference', 'main.py'))


# ---------------------------------------------------------------------------
# TOML subset
# ---------------------------------------------------------------------------

KEY_RE = re.compile(r'[ \t]*([A-Za-z0-9_-]+)[ \t]*=[ \t]*')
INT_RE = re.compile(r'-?(?:0|[1-9][0-9]*)')
STRING_ESCAPES = {'"': '"', '\\': '\\', 'n': '\n', 't': '\t', 'r': '\r'}


class SiteError(Exception):
    pass


def parse_string(line, i):
    """Parses a basic string starting at the opening quote; returns (value, index)."""
    if line[i:i + 1] != '"':
        raise SiteError('expected a string at %r' % line[i:])
    i += 1
    out = []
    while True:
        if i >= len(line):
            raise SiteError('unterminated string in %r' % line)
        c = line[i]
        if c == '"':
            return ''.join(out), i + 1
        if c == '\\':
            e = line[i + 1:i + 2]
            if e in STRING_ESCAPES:
                out.append(STRING_ESCAPES[e])
                i += 2
            elif e == 'u':
                out.append(chr(int(line[i + 2:i + 6], 16)))
                i += 6
            else:
                raise SiteError('bad escape \\%s' % e)
        else:
            out.append(c)
            i += 1


def parse_array(line, i):
    """Parses an array of basic strings starting at `[`; returns (value, index)."""
    i += 1
    items = []
    while True:
        while i < len(line) and line[i] in ' \t':
            i += 1
        if line[i:i + 1] == ']':
            return items, i + 1
        value, i = parse_string(line, i)
        items.append(value)
        while i < len(line) and line[i] in ' \t':
            i += 1
        if line[i:i + 1] == ',':
            i += 1
        elif line[i:i + 1] != ']':
            raise SiteError('bad array in %r' % line)


def parse_value(line, i):
    c = line[i:i + 1]
    if c == '"':
        return parse_string(line, i)
    if c == '[':
        return parse_array(line, i)
    if line.startswith('true', i):
        return True, i + 4
    if line.startswith('false', i):
        return False, i + 5
    m = INT_RE.match(line, i)
    if m:
        return int(m.group(0)), m.end()
    raise SiteError('bad value in %r' % line)


def parse_toml(text):
    """Parses the TOML subset: one `key = value` per line, comments, blank lines."""
    result = {}
    for line in text.split('\n'):
        stripped = line.strip(' \t')
        if not stripped or stripped.startswith('#'):
            continue
        m = KEY_RE.match(line)
        if not m:
            raise SiteError('bad line %r' % line)
        value, i = parse_value(line, m.end())
        rest = line[i:].lstrip(' \t')
        if rest and not rest.startswith('#'):
            raise SiteError('trailing text %r' % rest)
        result[m.group(1)] = value
    return result


# ---------------------------------------------------------------------------
# Content model
# ---------------------------------------------------------------------------

MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July',
          'August', 'September', 'October', 'November', 'December']
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')


def slugify(name):
    """Lowercases ASCII letters and reduces every other character to `-`."""
    out = []
    for ch in name:
        if 'A' <= ch <= 'Z':
            out.append(chr(ord(ch) + 32))
        elif 'a' <= ch <= 'z' or '0' <= ch <= '9':
            out.append(ch)
        else:
            out.append('-')
    return re.sub('-+', '-', ''.join(out)).strip('-')


def date_long(date):
    if not DATE_RE.match(date):
        raise SiteError('bad date %r' % date)
    year, month, day = date.split('-')
    return '%s %d, %s' % (MONTHS[int(month) - 1], int(day), year)


def split_front_matter(text, path):
    """Splits `+++` front matter from the body; returns (toml text, body)."""
    if not text.startswith('+++\n'):
        raise SiteError('%s: missing front matter' % path)
    lines = text[4:].split('\n')
    for i, line in enumerate(lines):
        if line == '+++':
            return '\n'.join(lines[:i]), '\n'.join(lines[i + 1:])
    raise SiteError('%s: unterminated front matter' % path)


def read_text(path):
    with open(path, 'rb') as f:
        return f.read().decode('utf-8')


def list_markdown(directory):
    if not os.path.isdir(directory):
        return []
    names = [n for n in os.listdir(directory)
             if n.endswith('.md') and os.path.isfile(os.path.join(directory, n))]
    return sorted(names)


def excerpt_source(body):
    """The body's first block: the lines before the first blank line."""
    lines = body.split('\n')
    i = 0
    while i < len(lines) and not lines[i].strip(' \t'):
        i += 1
    j = i
    while j < len(lines) and lines[j].strip(' \t'):
        j += 1
    return '\n'.join(lines[i:j])


def load_documents(directory, kind):
    """Reads every `.md` file in `directory` into a raw document record."""
    docs = []
    for name in list_markdown(directory):
        path = os.path.join(directory, name)
        fm_text, body = split_front_matter(read_text(path), path)
        fm = parse_toml(fm_text)
        if 'title' not in fm:
            raise SiteError('%s: missing title' % path)
        doc = {
            'title': fm['title'],
            'slug': fm.get('slug', name[:-3]),
            'draft': bool(fm.get('draft', False)),
            'body': body,
        }
        if kind == 'post':
            if 'date' not in fm:
                raise SiteError('%s: missing date' % path)
            doc['date'] = fm['date']
            seen, tags = set(), []
            for tag in fm.get('tags', []):
                if tag not in seen:
                    seen.add(tag)
                    tags.append(tag)
            doc['tags'] = tags
        docs.append(doc)
    return [d for d in docs if not d['draft']]


class Site:
    """The whole content model: configuration, posts, pages and tags."""

    def __init__(self, input_dir):
        self.config = parse_toml(read_text(os.path.join(input_dir, 'site.toml')))
        for key in ('title', 'base_url', 'posts_per_page', 'author'):
            if key not in self.config:
                raise SiteError('site.toml: missing %s' % key)
        self.base = self.config['base_url']
        self.per_page = self.config['posts_per_page']
        if not isinstance(self.per_page, int) or self.per_page < 1:
            raise SiteError('site.toml: posts_per_page must be a positive integer')

        posts = load_documents(os.path.join(input_dir, 'content', 'posts'), 'post')
        posts.sort(key=lambda d: d['slug'])
        posts.sort(key=lambda d: d['date'], reverse=True)
        self.posts = posts
        self.pages = sorted(
            load_documents(os.path.join(input_dir, 'content', 'pages'), 'page'),
            key=lambda d: d['slug'])

        for doc in self.posts + self.pages:
            doc['content'] = markdown.convert(doc['body'])
        for doc in self.posts:
            doc['excerpt'] = markdown.convert(excerpt_source(doc['body']))

        self.tag_names = []
        self.tag_slugs = {}
        seen = set()
        for post in self.posts:
            for tag in post['tags']:
                if tag not in seen:
                    seen.add(tag)
                    slug = slugify(tag)
                    if slug in self.tag_slugs:
                        raise SiteError('tag slug collision: %r' % slug)
                    self.tag_slugs[slug] = tag
                    self.tag_names.append(tag)
        self.tag_names.sort(key=slugify)
        self.tag_counts = {t: 0 for t in self.tag_names}
        for post in self.posts:
            for tag in post['tags']:
                self.tag_counts[tag] += 1

        self.total_pages = max(1, -(-len(self.posts) // self.per_page))

    # -- URLs ---------------------------------------------------------------

    def index_url(self, number):
        return '/' if number == 1 else '/page/%d/' % number

    def post_url(self, post):
        return '/posts/%s/' % post['slug']

    def page_url(self, page):
        return '/%s/' % page['slug']

    def tag_url(self, tag):
        return '/tags/%s/' % slugify(tag)

    def absolute(self, url):
        return self.base + url

    # -- Context objects ----------------------------------------------------

    def tag_link(self, tag):
        return {
            'name': tag,
            'slug': slugify(tag),
            'url': self.tag_url(tag),
            'post_count': self.tag_counts[tag],
        }

    def post_link(self, post):
        url = self.post_url(post)
        return {
            'title': post['title'],
            'slug': post['slug'],
            'url': url,
            'permalink': self.absolute(url),
            'date': post['date'],
            'date_long': date_long(post['date']),
        }

    def post_object(self, index):
        post = self.posts[index]
        url = self.post_url(post)
        older = self.posts[index + 1] if index + 1 < len(self.posts) else None
        newer = self.posts[index - 1] if index > 0 else None
        return {
            'title': post['title'],
            'slug': post['slug'],
            'url': url,
            'permalink': self.absolute(url),
            'date': post['date'],
            'date_long': date_long(post['date']),
            'tags': [self.tag_link(t) for t in post['tags']],
            'content': post['content'],
            'excerpt': post['excerpt'],
            'older': self.post_link(older) if older else None,
            'newer': self.post_link(newer) if newer else None,
        }

    def page_object(self, page):
        url = self.page_url(page)
        return {
            'title': page['title'],
            'slug': page['slug'],
            'url': url,
            'permalink': self.absolute(url),
            'content': page['content'],
        }

    def page_link(self, page):
        return {'title': page['title'], 'slug': page['slug'], 'url': self.page_url(page)}

    def pagination(self, number):
        return {
            'number': number,
            'total_pages': self.total_pages,
            'total_posts': len(self.posts),
            'has_prev': number > 1,
            'has_next': number < self.total_pages,
            'prev_url': self.index_url(number - 1) if number > 1 else None,
            'next_url': self.index_url(number + 1) if number < self.total_pages else None,
            'links': [{'number': n, 'url': self.index_url(n), 'current': n == number}
                      for n in range(1, self.total_pages + 1)],
        }

    def shared(self):
        return {
            'site': dict(self.config),
            'tags': [self.tag_link(t) for t in self.tag_names],
            'pages': [self.page_link(p) for p in self.pages],
        }


# ---------------------------------------------------------------------------
# XML output
# ---------------------------------------------------------------------------

def xml_text(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def xml_attr(s):
    return xml_text(s).replace('"', '&quot;')


def build_feed(site):
    posts = site.posts[:site.per_page]
    updated = (site.posts[0]['date'] if site.posts else '1970-01-01') + 'T00:00:00Z'
    out = ['<?xml version="1.0" encoding="utf-8"?>',
           '<feed xmlns="http://www.w3.org/2005/Atom">',
           '  <title>%s</title>' % xml_text(site.config['title']),
           '  <id>%s</id>' % xml_text(site.absolute('/')),
           '  <updated>%s</updated>' % updated,
           '  <link href="%s" rel="alternate"/>' % xml_attr(site.absolute('/')),
           '  <link href="%s" rel="self"/>' % xml_attr(site.absolute('/feed.xml')),
           '  <author>',
           '    <name>%s</name>' % xml_text(site.config['author']),
           '  </author>']
    for post in posts:
        url = site.absolute(site.post_url(post))
        out += ['  <entry>',
                '    <title>%s</title>' % xml_text(post['title']),
                '    <id>%s</id>' % xml_text(url),
                '    <updated>%sT00:00:00Z</updated>' % post['date'],
                '    <link href="%s" rel="alternate"/>' % xml_attr(url),
                '    <content type="html">%s</content>' % xml_text(post['content']),
                '  </entry>']
    out.append('</feed>')
    return '\n'.join(out) + '\n'


def build_sitemap(site):
    out = ['<?xml version="1.0" encoding="utf-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']

    def url(loc, lastmod=None):
        out.append('  <url>')
        out.append('    <loc>%s</loc>' % xml_text(loc))
        if lastmod:
            out.append('    <lastmod>%s</lastmod>' % lastmod)
        out.append('  </url>')

    for n in range(1, site.total_pages + 1):
        url(site.absolute(site.index_url(n)))
    for post in site.posts:
        url(site.absolute(site.post_url(post)), post['date'])
    for page in site.pages:
        url(site.absolute(site.page_url(page)))
    url(site.absolute('/tags/'))
    for tag in site.tag_names:
        url(site.absolute(site.tag_url(tag)))
    out.append('</urlset>')
    return '\n'.join(out) + '\n'


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def load_templates(input_dir):
    directory = os.path.join(input_dir, 'templates')
    sources = {}
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if name.endswith('.html') and os.path.isfile(path):
            text = read_text(path)
            sources[name] = text[:-1] if text.endswith('\n') else text
    for name in ('index.html', 'post.html', 'page.html', 'tag.html', 'tags.html'):
        if name not in sources:
            raise SiteError('templates/%s is missing' % name)
    return sources


class Renderer:
    def __init__(self, sources, on_render=None):
        self.engine = jinja.Engine(sources, {})
        self.on_render = on_render

    def render(self, name, context, rel_path):
        scope = jinja.Scope(None)
        scope.vars.update(context)
        out = []
        self.engine.render_template(name, scope, out)
        text = ''.join(out)
        if self.on_render:
            self.on_render(name, context, rel_path, text)
        return text


def write_file(out_dir, rel_path, text):
    path = os.path.join(out_dir, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(text.encode('utf-8'))


def copy_static(input_dir, out_dir):
    root = os.path.join(input_dir, 'static')
    if not os.path.isdir(root):
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            src = os.path.join(dirpath, name)
            rel = os.path.relpath(src, root)
            dst = os.path.join(out_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(src, 'rb') as f:
                data = f.read()
            with open(dst, 'wb') as f:
                f.write(data)


def generate(input_dir, out_dir, on_render=None):
    site = Site(input_dir)
    renderer = Renderer(load_templates(input_dir), on_render)
    shared = site.shared()

    posts = [site.post_object(i) for i in range(len(site.posts))]

    for number in range(1, site.total_pages + 1):
        start = (number - 1) * site.per_page
        context = dict(shared)
        context['posts'] = posts[start:start + site.per_page]
        context['pagination'] = site.pagination(number)
        rel = 'index.html' if number == 1 else os.path.join('page', str(number), 'index.html')
        write_file(out_dir, rel, renderer.render('index.html', context, rel))

    for post in posts:
        context = dict(shared)
        context['post'] = post
        rel = os.path.join('posts', post['slug'], 'index.html')
        write_file(out_dir, rel, renderer.render('post.html', context, rel))

    for page in site.pages:
        context = dict(shared)
        context['page'] = site.page_object(page)
        rel = os.path.join(page['slug'], 'index.html')
        write_file(out_dir, rel, renderer.render('page.html', context, rel))

    rel = os.path.join('tags', 'index.html')
    write_file(out_dir, rel, renderer.render('tags.html', dict(shared), rel))

    by_slug = {p['slug']: p for p in posts}
    for name in site.tag_names:
        tag = site.tag_link(name)
        tag['posts'] = [by_slug[p['slug']] for p in site.posts if name in p['tags']]
        context = dict(shared)
        context['tag'] = tag
        context['posts'] = tag['posts']
        rel = os.path.join('tags', tag['slug'], 'index.html')
        write_file(out_dir, rel, renderer.render('tag.html', context, rel))

    write_file(out_dir, 'feed.xml', build_feed(site))
    write_file(out_dir, 'sitemap.xml', build_sitemap(site))
    copy_static(input_dir, out_dir)


def main():
    sys.setrecursionlimit(20000)
    if len(sys.argv) != 3:
        sys.stderr.write('usage: main.py <input dir> <output dir>\n')
        return 2
    generate(sys.argv[1], sys.argv[2])
    return 0


if __name__ == '__main__':
    sys.exit(main())
