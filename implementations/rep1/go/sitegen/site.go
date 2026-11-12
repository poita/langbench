package sitegen

import (
	"errors"
	"fmt"
	"io/fs"
	"slices"
	"strings"

	"example.com/sitegen/markdown"
	"example.com/sitegen/tmpl"
	"example.com/sitegen/toml"
)

// A Post is a published post.
type Post struct {
	Title     string
	Slug      string
	Date      string // YYYY-MM-DD
	Tags      []*Tag // in the post's own order, duplicates removed
	Content   string // the body converted to HTML
	Excerpt   string // the first block of the body converted to HTML
	URL       string // /posts/<slug>/
	Permalink string // base URL + URL

	// Older and Newer are the neighbours in the site-wide canonical order
	// (newest first); nil at either end.
	Older, Newer *Post
}

// A Page is a published page.
type Page struct {
	Title     string
	Slug      string
	Content   string
	URL       string // /<slug>/
	Permalink string
}

// A Tag is a tag carried by at least one published post.
type Tag struct {
	Name  string
	Slug  string
	URL   string  // /tags/<slug>/
	Posts []*Post // in canonical order
}

// A Site is a loaded site: its configuration, its content converted to HTML
// and its templates, ready to be generated.
type Site struct {
	// Config is the parsed site.toml; every key is available to templates as
	// site.<key>.
	Config *toml.Document

	Title        string
	BaseURL      string // without a trailing slash
	Author       string
	PostsPerPage int

	// Posts are the published posts in canonical order: newest first, ties
	// broken by slug ascending.
	Posts []*Post
	// Pages are the published pages ordered by slug.
	Pages []*Page
	// Tags are the existing tags ordered by slug.
	Tags []*Tag

	fsys      fs.FS
	templates *tmpl.Set
}

// TotalPages is the number of index pages: at least one, even without posts.
func (s *Site) TotalPages() int {
	n := (len(s.Posts) + s.PostsPerPage - 1) / s.PostsPerPage
	return max(1, n)
}

// Load reads a site source from fsys and builds the content model: it parses
// the configuration and front matter, drops drafts, sorts posts and pages,
// collects tags and converts every body and excerpt to HTML exactly once.
// Template syntax is not checked until a template is rendered.
func Load(fsys fs.FS) (*Site, error) {
	cfgSrc, err := fs.ReadFile(fsys, "site.toml")
	if err != nil {
		return nil, fmt.Errorf("reading site.toml: %w", err)
	}
	cfg, err := toml.Parse(string(cfgSrc))
	if err != nil {
		return nil, fmt.Errorf("site.toml: %w", err)
	}
	s := &Site{Config: cfg, fsys: fsys, templates: tmpl.NewSet()}
	var ok bool
	if s.Title, ok = cfg.String("title"); !ok {
		return nil, errors.New("site.toml: missing string key \"title\"")
	}
	if s.BaseURL, ok = cfg.String("base_url"); !ok {
		return nil, errors.New("site.toml: missing string key \"base_url\"")
	}
	if s.Author, ok = cfg.String("author"); !ok {
		return nil, errors.New("site.toml: missing string key \"author\"")
	}
	ppp, ok := cfg.Int("posts_per_page")
	if !ok || ppp < 1 {
		return nil, errors.New("site.toml: \"posts_per_page\" must be an integer >= 1")
	}
	s.PostsPerPage = int(ppp)

	if err := s.loadTemplates(); err != nil {
		return nil, err
	}
	if err := s.loadPosts(); err != nil {
		return nil, err
	}
	if err := s.loadPages(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Site) loadTemplates() error {
	entries, err := readDir(s.fsys, "templates")
	if err != nil {
		return err
	}
	for _, name := range entries {
		if !strings.HasSuffix(name, ".html") {
			continue
		}
		src, err := fs.ReadFile(s.fsys, "templates/"+name)
		if err != nil {
			return err
		}
		s.templates.Add(name, strings.TrimSuffix(string(src), "\n"))
	}
	return nil
}

// readDir lists the regular files directly inside dir, sorted by name. A
// missing directory is empty.
func readDir(fsys fs.FS, dir string) ([]string, error) {
	entries, err := fs.ReadDir(fsys, dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		typ := e.Type()
		if typ&fs.ModeSymlink != 0 {
			if info, err := fs.Stat(fsys, dir+"/"+e.Name()); err == nil {
				typ = info.Mode().Type()
			}
		}
		if typ.IsRegular() {
			names = append(names, e.Name())
		}
	}
	return names, nil
}

func (s *Site) readContent(dir string) (map[string]*contentFile, []string, error) {
	names, err := readDir(s.fsys, dir)
	if err != nil {
		return nil, nil, err
	}
	files := map[string]*contentFile{}
	var order []string
	for _, name := range names {
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		path := dir + "/" + name
		src, err := fs.ReadFile(s.fsys, path)
		if err != nil {
			return nil, nil, err
		}
		cf, err := parseContent(name, string(src))
		if err != nil {
			return nil, nil, fmt.Errorf("%s: %w", path, err)
		}
		files[path] = cf
		order = append(order, path)
	}
	return files, order, nil
}

// postSource is a post together with the tag names its front matter lists.
type postSource struct {
	post     *Post
	tagNames []string
}

func (s *Site) loadPosts() error {
	files, order, err := s.readContent("content/posts")
	if err != nil {
		return err
	}
	var srcs []postSource
	for _, path := range order {
		cf := files[path]
		if cf.draft {
			continue
		}
		date, ok := cf.doc.String("date")
		if !ok {
			return fmt.Errorf("%s: missing string key \"date\"", path)
		}
		p := &Post{Title: cf.title, Slug: cf.slug, Date: date}
		p.URL = "/posts/" + p.Slug + "/"
		p.Permalink = s.BaseURL + p.URL
		p.Content = markdown.ToHTML(cf.body)
		p.Excerpt = markdown.ToHTML(excerptSource(cf.body))
		var names []string
		if v, present := cf.doc.Get("tags"); present {
			if v.Kind != toml.Array {
				return fmt.Errorf("%s: \"tags\" must be an array of strings", path)
			}
			names = v.Strings
		}
		srcs = append(srcs, postSource{p, names})
	}
	slices.SortStableFunc(srcs, func(a, b postSource) int {
		if c := strings.Compare(b.post.Date, a.post.Date); c != 0 {
			return c // newest first
		}
		return strings.Compare(a.post.Slug, b.post.Slug)
	})
	s.Posts = make([]*Post, len(srcs))
	for i, src := range srcs {
		s.Posts[i] = src.post
		if i > 0 {
			src.post.Newer = s.Posts[i-1]
			s.Posts[i-1].Older = src.post
		}
	}
	s.collectTags(srcs)
	return nil
}

func (s *Site) loadPages() error {
	files, order, err := s.readContent("content/pages")
	if err != nil {
		return err
	}
	for _, path := range order {
		cf := files[path]
		if cf.draft {
			continue
		}
		pg := &Page{Title: cf.title, Slug: cf.slug}
		pg.URL = "/" + pg.Slug + "/"
		pg.Permalink = s.BaseURL + pg.URL
		pg.Content = markdown.ToHTML(cf.body)
		s.Pages = append(s.Pages, pg)
	}
	slices.SortStableFunc(s.Pages, func(a, b *Page) int { return strings.Compare(a.Slug, b.Slug) })
	return nil
}

// collectTags builds the tag list in O(K + T log T) for K (post, tag) pairs
// and T tags: posts are visited once, in canonical order, so each tag's post
// list comes out in canonical order with no further sorting.
func (s *Site) collectTags(srcs []postSource) {
	byName := map[string]*Tag{}
	seen := map[string]bool{}
	for _, src := range srcs {
		clear(seen)
		for _, name := range src.tagNames {
			if seen[name] {
				continue
			}
			seen[name] = true
			t := byName[name]
			if t == nil {
				slug := TagSlug(name)
				t = &Tag{Name: name, Slug: slug, URL: "/tags/" + slug + "/"}
				byName[name] = t
				s.Tags = append(s.Tags, t)
			}
			t.Posts = append(t.Posts, src.post)
			src.post.Tags = append(src.post.Tags, t)
		}
	}
	slices.SortFunc(s.Tags, func(a, b *Tag) int { return strings.Compare(a.Slug, b.Slug) })
}
