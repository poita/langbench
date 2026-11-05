package sitegen

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"

	"example.com/sitegen/tmpl"
)

// Output is the set of files that make up a generated site.
type Output struct {
	Files []File
}

// BuildDir loads the site in directory dir and generates it.
func BuildDir(dir string) (*Output, error) {
	return Build(os.DirFS(dir))
}

// Build loads the site source from fsys and generates it.
func Build(fsys fs.FS) (*Output, error) {
	site, err := Load(fsys)
	if err != nil {
		return nil, err
	}
	return site.Generate()
}

// Generate renders every page, the feed and the sitemap, and adds the static
// files. The order of Output.Files is deterministic: index pages, posts,
// pages, the tag index, tag pages, feed.xml, sitemap.xml, static files.
func (s *Site) Generate() (*Output, error) {
	engine := tmpl.New()
	for name, src := range s.Templates {
		engine.Add(name, src)
	}
	v := s.buildValues()
	out := &Output{}

	render := func(outPath, entry string, ctx *tmpl.Dict) error {
		html, err := engine.Render(entry, ctx)
		if err != nil {
			return fmt.Errorf("rendering %s (%s): %w", outPath, entry, err)
		}
		out.Files = append(out.Files, File{Path: outPath, Data: []byte(html)})
		return nil
	}

	// Index pages.
	perPage := s.Config.PostsPerPage
	for n := 1; n <= v.total; n++ {
		lo := (n - 1) * perPage
		if lo > len(v.posts) {
			lo = len(v.posts)
		}
		hi := lo + perPage
		if hi > len(v.posts) {
			hi = len(v.posts)
		}
		ctx := v.root()
		ctx.Set("posts", v.posts[lo:hi:hi])
		ctx.Set("pagination", v.pagination(n, len(s.Posts)))
		outPath := "index.html"
		if n > 1 {
			outPath = "page/" + strconv.Itoa(n) + "/index.html"
		}
		if err := render(outPath, "index.html", ctx); err != nil {
			return nil, err
		}
	}
	for i, p := range s.Posts {
		ctx := v.root()
		ctx.Set("post", v.posts[i])
		if err := render("posts/"+p.Slug+"/index.html", "post.html", ctx); err != nil {
			return nil, err
		}
	}
	for i, p := range s.Pages {
		ctx := v.root()
		ctx.Set("page", v.pageDicts[i])
		if err := render(p.Slug+"/index.html", "page.html", ctx); err != nil {
			return nil, err
		}
	}
	if err := render("tags/index.html", "tags.html", v.root()); err != nil {
		return nil, err
	}
	for i, t := range s.Tags {
		ctx := v.root()
		td := v.tagDicts[i]
		posts, _ := td.Get("posts")
		ctx.Set("tag", td)
		ctx.Set("posts", posts)
		if err := render("tags/"+t.Slug+"/index.html", "tag.html", ctx); err != nil {
			return nil, err
		}
	}

	out.Files = append(out.Files,
		File{Path: "feed.xml", Data: s.feed(v.contents)},
		File{Path: "sitemap.xml", Data: s.sitemap(v.total)},
	)
	out.Files = append(out.Files, s.Static...)
	return out, nil
}

// WriteDir writes the files below dir, creating directories as needed. Each
// directory is created once. Paths that would escape dir are rejected.
func (o *Output) WriteDir(dir string) error {
	made := map[string]bool{}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	made[dir] = true
	for _, f := range o.Files {
		if !fs.ValidPath(f.Path) || f.Path == "." {
			return fmt.Errorf("invalid output path %q", f.Path)
		}
		full := filepath.Join(dir, filepath.FromSlash(f.Path))
		if d := filepath.Dir(full); !made[d] {
			if err := os.MkdirAll(d, 0o755); err != nil {
				return err
			}
			made[d] = true
		}
		if err := os.WriteFile(full, f.Data, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// Paths returns the output paths in order.
func (o *Output) Paths() []string {
	paths := make([]string, len(o.Files))
	for i, f := range o.Files {
		paths[i] = f.Path
	}
	return paths
}
