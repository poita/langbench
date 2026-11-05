package sitegen

import (
	"errors"
	"fmt"
	"io/fs"
	"path"
	"sort"
	"strings"

	"example.com/sitegen/toml"
)

// File is an output file: a slash-separated path relative to the output
// directory and its contents.
type File struct {
	Path string
	Data []byte
}

// Config is the content of site.toml.
type Config struct {
	Title        string
	BaseURL      string // without a trailing slash
	Author       string
	PostsPerPage int
	// Doc is the whole parsed site.toml, including keys not listed above.
	Doc *toml.Document
}

// Site is a loaded site source: configuration, published posts and pages in
// their canonical order, tags, template sources and static files.
type Site struct {
	Config    Config
	Posts     []*Post // published posts, newest first
	Pages     []*Page // published pages, by slug
	Tags      []*Tag  // by slug
	Templates map[string]string
	Static    []File
}

// RequiredTemplates are the entry-point templates every site must provide.
var RequiredTemplates = []string{"index.html", "post.html", "page.html", "tag.html", "tags.html"}

// Load reads a site source tree from fsys.
func Load(fsys fs.FS) (*Site, error) {
	s := &Site{Templates: map[string]string{}}

	raw, err := fs.ReadFile(fsys, "site.toml")
	if err != nil {
		return nil, fmt.Errorf("reading site.toml: %w", err)
	}
	if err := s.parseConfig(string(raw)); err != nil {
		return nil, fmt.Errorf("site.toml: %w", err)
	}

	var posts []*Post
	var pages []*Page
	err = eachFile(fsys, "content/posts", ".md", func(name, src string) error {
		p, err := parsePost(name, src)
		if err != nil {
			return fmt.Errorf("content/posts/%s: %w", name, err)
		}
		if !p.Draft {
			posts = append(posts, p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	err = eachFile(fsys, "content/pages", ".md", func(name, src string) error {
		p, err := parsePage(name, src)
		if err != nil {
			return fmt.Errorf("content/pages/%s: %w", name, err)
		}
		if !p.Draft {
			pages = append(pages, p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	err = eachFile(fsys, "templates", ".html", func(name, src string) error {
		s.Templates[name] = strings.TrimSuffix(src, "\n")
		return nil
	})
	if err != nil {
		return nil, err
	}
	for _, name := range RequiredTemplates {
		if _, ok := s.Templates[name]; !ok {
			return nil, fmt.Errorf("templates/%s is missing", name)
		}
	}

	sortPosts(posts)
	sortPages(pages)
	s.Posts, s.Pages = posts, pages
	s.Tags = collectTags(posts)

	if err := s.loadStatic(fsys); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Site) parseConfig(src string) error {
	doc, err := toml.Parse(src)
	if err != nil {
		return err
	}
	c := &s.Config
	c.Doc = doc
	var ok bool
	if c.Title, ok = doc.String("title"); !ok {
		return errors.New("title must be a string")
	}
	if c.BaseURL, ok = doc.String("base_url"); !ok {
		return errors.New("base_url must be a string")
	}
	if c.Author, ok = doc.String("author"); !ok {
		return errors.New("author must be a string")
	}
	n, ok := doc.Int("posts_per_page")
	if !ok || n < 1 || n > 1<<31 {
		return errors.New("posts_per_page must be an integer >= 1")
	}
	c.PostsPerPage = int(n)
	return nil
}

// eachFile calls fn with the name and contents of every regular file directly
// inside dir whose name ends with suffix, in name order. A missing directory
// is not an error.
func eachFile(fsys fs.FS, dir, suffix string, fn func(name, src string) error) error {
	entries, err := fs.ReadDir(fsys, dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.Type().IsRegular() || !strings.HasSuffix(e.Name(), suffix) {
			continue
		}
		data, err := fs.ReadFile(fsys, path.Join(dir, e.Name()))
		if err != nil {
			return err
		}
		if err := fn(e.Name(), string(data)); err != nil {
			return err
		}
	}
	return nil
}

func parsePost(filename, src string) (*Post, error) {
	front, body, err := splitFrontMatter(src)
	if err != nil {
		return nil, err
	}
	doc, err := toml.Parse(front)
	if err != nil {
		return nil, err
	}
	p := &Post{Body: body}
	var ok bool
	if p.Title, ok = doc.String("title"); !ok {
		return nil, errors.New("title must be a string")
	}
	if p.Date, ok = doc.String("date"); !ok {
		return nil, errors.New("date must be a string")
	}
	if p.DateLong, err = LongDate(p.Date); err != nil {
		return nil, err
	}
	p.Slug = strings.TrimSuffix(filename, ".md")
	if v, found := doc.Lookup("slug"); found {
		if v.Kind != toml.String {
			return nil, errors.New("slug must be a string")
		}
		p.Slug = v.Str
	}
	if v, found := doc.Lookup("tags"); found {
		if v.Kind != toml.Array {
			return nil, errors.New("tags must be an array of strings")
		}
		p.Tags = v.Array
	}
	if v, found := doc.Lookup("draft"); found {
		if v.Kind != toml.Boolean {
			return nil, errors.New("draft must be a boolean")
		}
		p.Draft = v.Bool
	}
	p.URL = "/posts/" + p.Slug + "/"
	return p, nil
}

func parsePage(filename, src string) (*Page, error) {
	front, body, err := splitFrontMatter(src)
	if err != nil {
		return nil, err
	}
	doc, err := toml.Parse(front)
	if err != nil {
		return nil, err
	}
	p := &Page{Body: body}
	var ok bool
	if p.Title, ok = doc.String("title"); !ok {
		return nil, errors.New("title must be a string")
	}
	p.Slug = strings.TrimSuffix(filename, ".md")
	if v, found := doc.Lookup("slug"); found {
		if v.Kind != toml.String {
			return nil, errors.New("slug must be a string")
		}
		p.Slug = v.Str
	}
	if v, found := doc.Lookup("draft"); found {
		if v.Kind != toml.Boolean {
			return nil, errors.New("draft must be a boolean")
		}
		p.Draft = v.Bool
	}
	p.URL = "/" + p.Slug + "/"
	return p, nil
}

// loadStatic reads every file under static/ (including dot files).
func (s *Site) loadStatic(fsys fs.FS) error {
	if info, err := fs.Stat(fsys, "static"); err != nil || !info.IsDir() {
		return nil
	}
	err := fs.WalkDir(fsys, "static", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		data, err := fs.ReadFile(fsys, p)
		if err != nil {
			return err
		}
		s.Static = append(s.Static, File{Path: strings.TrimPrefix(p, "static/"), Data: data})
		return nil
	})
	if err != nil {
		return fmt.Errorf("reading static files: %w", err)
	}
	sort.Slice(s.Static, func(i, j int) bool { return s.Static[i].Path < s.Static[j].Path })
	return nil
}
