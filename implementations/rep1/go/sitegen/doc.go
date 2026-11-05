// Package sitegen is a small static site generator.
//
// It reads a source tree (a TOML-subset site.toml, Markdown content with
// front matter, Jinja-style templates and static files) and produces a
// complete static website: an index with pagination, one page per post and
// page, tag pages, an Atom feed, a sitemap and a copy of the static files.
//
// The package is built from independent parts, each in its own package:
//
//   - example.com/sitegen/toml     the TOML subset used by configuration and front matter
//   - example.com/sitegen/markdown the CommonMark subset converter
//   - example.com/sitegen/tmpl     the template engine
//
// and this package, which defines the content model (posts, pages, tags,
// slugs, ordering, pagination), builds the values handed to templates and
// renders every output file.
//
// Typical use:
//
//	out, err := sitegen.BuildDir("mysite")
//	if err != nil {
//		log.Fatal(err)
//	}
//	err = out.WriteDir("public")
//
// To work on an in-memory tree, pass any fs.FS to Build.
package sitegen
