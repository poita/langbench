package sitegen

import (
	"fmt"
	"io/fs"
	"strconv"

	"example.com/sitegen/tmpl"
)

// Generate renders every page of the site, the feed and the sitemap, and
// copies the static files, writing them all to sink. Templates are parsed and
// checked when first rendered, so template errors are reported here.
func (s *Site) Generate(sink Sink) error {
	v := s.buildValues()

	render := func(out, template string, vars map[string]tmpl.Value) error {
		vars["site"] = v.site
		vars["tags"] = v.tags
		vars["pages"] = v.pages
		html, err := s.templates.Render(template, vars)
		if err != nil {
			return fmt.Errorf("rendering %s (%s): %w", out, template, err)
		}
		return sink.WriteFile(out, []byte(html))
	}

	// Index pages.
	per := s.PostsPerPage
	for n := 1; n <= s.TotalPages(); n++ {
		lo := min((n-1)*per, len(v.posts))
		hi := min(n*per, len(v.posts))
		out := "index.html"
		if n > 1 {
			out = "page/" + strconv.Itoa(n) + "/index.html"
		}
		err := render(out, "index.html", map[string]tmpl.Value{
			"posts":      v.posts[lo:hi:hi],
			"pagination": s.pagination(n),
		})
		if err != nil {
			return err
		}
	}
	for i, p := range s.Posts {
		err := render("posts/"+p.Slug+"/index.html", "post.html", map[string]tmpl.Value{"post": v.posts[i]})
		if err != nil {
			return err
		}
	}
	for i, pg := range s.Pages {
		err := render(pg.Slug+"/index.html", "page.html", map[string]tmpl.Value{"page": v.pageFull[i]})
		if err != nil {
			return err
		}
	}
	if err := render("tags/index.html", "tags.html", map[string]tmpl.Value{}); err != nil {
		return err
	}
	for i, t := range s.Tags {
		tag := v.tagFull[i].(*tmpl.Dict)
		posts, _ := tag.Get("posts")
		err := render("tags/"+t.Slug+"/index.html", "tag.html", map[string]tmpl.Value{"tag": tag, "posts": posts})
		if err != nil {
			return err
		}
	}

	if err := sink.WriteFile("feed.xml", []byte(s.Feed())); err != nil {
		return err
	}
	if err := sink.WriteFile("sitemap.xml", []byte(s.Sitemap())); err != nil {
		return err
	}
	return s.copyStatic(sink)
}

// copyStatic copies every file below static/ to the same relative path.
func (s *Site) copyStatic(sink Sink) error {
	if _, err := fs.Stat(s.fsys, "static"); err != nil {
		return nil // no static directory
	}
	return fs.WalkDir(s.fsys, "static", func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if info, err := fs.Stat(s.fsys, path); err != nil || !info.Mode().IsRegular() {
			return nil
		}
		data, err := fs.ReadFile(s.fsys, path)
		if err != nil {
			return err
		}
		return sink.WriteFile(path[len("static/"):], data)
	})
}

// Build loads the site in fsys and generates it into sink.
func Build(fsys fs.FS, sink Sink) error {
	s, err := Load(fsys)
	if err != nil {
		return err
	}
	return s.Generate(sink)
}
