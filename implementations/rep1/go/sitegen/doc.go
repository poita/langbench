// Package sitegen is a static site generator.
//
// It reads a site source — a TOML-subset configuration file, Markdown content
// with front matter, Jinja-style templates and static files — and produces a
// complete static website: one page per post, page and tag, paginated index
// pages, an Atom feed and a sitemap.
//
// The generator is built from three self-contained packages that can also be
// used on their own: [example.com/sitegen/toml] (the configuration reader),
// [example.com/sitegen/markdown] (the Markdown to HTML converter) and
// [example.com/sitegen/tmpl] (the template engine).
//
// Typical use:
//
//	site, err := sitegen.Load(os.DirFS("mysite"))
//	if err != nil { ... }
//	err = site.Generate(sitegen.DirSink("public"))
//
// Input layout (see the README for the full description):
//
//	site.toml            title, base_url, author, posts_per_page and anything else
//	content/posts/*.md   posts, with front matter
//	content/pages/*.md   pages, with front matter
//	templates/*.html     index.html, post.html, page.html, tag.html, tags.html + helpers
//	static/**            copied verbatim
package sitegen
