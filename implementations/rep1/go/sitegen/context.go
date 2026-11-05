package sitegen

import (
	"example.com/sitegen/markdown"
	"example.com/sitegen/tmpl"
	"example.com/sitegen/toml"
)

// values holds every template value of a site. Each dict and list is built
// exactly once and shared by reference wherever it appears.
type values struct {
	site      *tmpl.Dict
	tagLinks  tmpl.List // tag links in tag order
	pageLinks tmpl.List // page links in page order
	posts     tmpl.List // full post dicts in canonical order
	pageDicts []*tmpl.Dict
	tagDicts  []*tmpl.Dict
	contents  []string // HTML of each post, parallel to Site.Posts (reused by the feed)

	// pagerLinks[n-1] holds the two link dicts of index page n: not current, current.
	pagerLinks [][2]*tmpl.Dict
	total      int // total number of index pages
}

func tomlValue(v toml.Value) tmpl.Value {
	switch v.Kind {
	case toml.String:
		return v.Str
	case toml.Integer:
		return v.Int
	case toml.Boolean:
		return v.Bool
	}
	return tmpl.StringList(v.Array)
}

// buildValues converts the content model into template values.
func (s *Site) buildValues() *values {
	cfg := &s.Config
	v := &values{}

	v.site = tmpl.NewDict()
	for _, e := range cfg.Doc.Entries {
		v.site.Set(e.Key, tomlValue(e.Value))
	}

	// Tag links, shared by the tags list and by every post.
	linkByName := make(map[string]*tmpl.Dict, len(s.Tags))
	v.tagLinks = make(tmpl.List, len(s.Tags))
	for i, t := range s.Tags {
		d := tmpl.NewDict()
		d.Set("name", t.Name)
		d.Set("slug", t.Slug)
		d.Set("url", t.URL)
		d.Set("post_count", int64(len(t.Posts)))
		linkByName[t.Name] = d
		v.tagLinks[i] = d
	}

	v.pageLinks = make(tmpl.List, len(s.Pages))
	v.pageDicts = make([]*tmpl.Dict, len(s.Pages))
	for i, p := range s.Pages {
		l := tmpl.NewDict()
		l.Set("title", p.Title)
		l.Set("slug", p.Slug)
		l.Set("url", p.URL)
		v.pageLinks[i] = l

		d := tmpl.NewDict()
		d.Set("title", p.Title)
		d.Set("slug", p.Slug)
		d.Set("url", p.URL)
		d.Set("permalink", cfg.BaseURL+p.URL)
		d.Set("content", markdown.ToHTML(p.Body))
		v.pageDicts[i] = d
	}

	// Post links first (older/newer refer to neighbours), then full posts.
	postLinks := make([]*tmpl.Dict, len(s.Posts))
	for i, p := range s.Posts {
		d := tmpl.NewDict()
		d.Set("title", p.Title)
		d.Set("slug", p.Slug)
		d.Set("url", p.URL)
		d.Set("permalink", cfg.BaseURL+p.URL)
		d.Set("date", p.Date)
		d.Set("date_long", p.DateLong)
		postLinks[i] = d
	}
	v.posts = make(tmpl.List, len(s.Posts))
	v.contents = make([]string, len(s.Posts))
	postDicts := make(map[*Post]*tmpl.Dict, len(s.Posts))
	for i, p := range s.Posts {
		tags := make(tmpl.List, len(p.Tags))
		for j, name := range p.Tags {
			tags[j] = linkByName[name]
		}
		v.contents[i] = markdown.ToHTML(p.Body)
		d := tmpl.NewDict()
		d.Set("title", p.Title)
		d.Set("slug", p.Slug)
		d.Set("url", p.URL)
		d.Set("permalink", cfg.BaseURL+p.URL)
		d.Set("date", p.Date)
		d.Set("date_long", p.DateLong)
		d.Set("tags", tags)
		d.Set("content", v.contents[i])
		d.Set("excerpt", markdown.ToHTML(firstBlock(p.Body)))
		if i+1 < len(s.Posts) {
			d.Set("older", postLinks[i+1])
		} else {
			d.Set("older", nil)
		}
		if i > 0 {
			d.Set("newer", postLinks[i-1])
		} else {
			d.Set("newer", nil)
		}
		v.posts[i] = d
		postDicts[p] = d
	}

	v.tagDicts = make([]*tmpl.Dict, len(s.Tags))
	for i, t := range s.Tags {
		posts := make(tmpl.List, len(t.Posts))
		for j, p := range t.Posts {
			posts[j] = postDicts[p]
		}
		d := tmpl.NewDict()
		d.Set("name", t.Name)
		d.Set("slug", t.Slug)
		d.Set("url", t.URL)
		d.Set("post_count", int64(len(t.Posts)))
		d.Set("posts", posts)
		v.tagDicts[i] = d
	}

	v.total = totalPages(len(s.Posts), cfg.PostsPerPage)
	v.pagerLinks = make([][2]*tmpl.Dict, v.total)
	for n := 1; n <= v.total; n++ {
		url := indexURL(n)
		for cur := 0; cur < 2; cur++ {
			d := tmpl.NewDict()
			d.Set("number", int64(n))
			d.Set("url", url)
			d.Set("current", cur == 1)
			v.pagerLinks[n-1][cur] = d
		}
	}
	return v
}

// root returns a fresh root scope holding the three shared variables.
func (v *values) root() *tmpl.Dict {
	d := tmpl.NewDict()
	d.Set("site", v.site)
	d.Set("tags", v.tagLinks)
	d.Set("pages", v.pageLinks)
	return d
}

// pagination builds the pagination dict of index page n (1-based).
func (v *values) pagination(n, totalPosts int) *tmpl.Dict {
	links := make(tmpl.List, v.total)
	for i := range links {
		cur := 0
		if i+1 == n {
			cur = 1
		}
		links[i] = v.pagerLinks[i][cur]
	}
	d := tmpl.NewDict()
	d.Set("number", int64(n))
	d.Set("total_pages", int64(v.total))
	d.Set("total_posts", int64(totalPosts))
	d.Set("has_prev", n > 1)
	d.Set("has_next", n < v.total)
	if n > 1 {
		d.Set("prev_url", indexURL(n-1))
	} else {
		d.Set("prev_url", nil)
	}
	if n < v.total {
		d.Set("next_url", indexURL(n+1))
	} else {
		d.Set("next_url", nil)
	}
	d.Set("links", links)
	return d
}
