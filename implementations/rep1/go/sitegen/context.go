package sitegen

import (
	"strconv"

	"example.com/sitegen/tmpl"
	"example.com/sitegen/toml"
)

// values holds the template values of a site. Post, page and tag objects and
// their links are built once and shared by every page that shows them.
type values struct {
	site     *tmpl.Dict
	tags     []tmpl.Value // tag links, in tag order
	pages    []tmpl.Value // page links, in page order
	posts    []tmpl.Value // post objects, in canonical order
	tagFull  []tmpl.Value // full tag objects, parallel to Site.Tags
	pageFull []tmpl.Value // page objects, parallel to Site.Pages
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
	l := make([]tmpl.Value, len(v.Strings))
	for i, s := range v.Strings {
		l[i] = s
	}
	return l
}

func (s *Site) buildValues() *values {
	v := &values{}

	v.site = tmpl.NewDict(len(s.Config.Entries()))
	for _, e := range s.Config.Entries() {
		v.site.Set(e.Key, tomlValue(e.Value))
	}

	// Tag links and full tag objects. The full objects need the post objects,
	// so only the links are built here.
	tagLink := make(map[*Tag]*tmpl.Dict, len(s.Tags))
	v.tags = make([]tmpl.Value, len(s.Tags))
	for i, t := range s.Tags {
		d := tmpl.NewDict(4)
		d.Set("name", t.Name)
		d.Set("slug", t.Slug)
		d.Set("url", t.URL)
		d.Set("post_count", int64(len(t.Posts)))
		tagLink[t] = d
		v.tags[i] = d
	}

	// Post links, used for older/newer navigation.
	postLink := make(map[*Post]*tmpl.Dict, len(s.Posts))
	for _, p := range s.Posts {
		d := tmpl.NewDict(6)
		d.Set("title", p.Title)
		d.Set("slug", p.Slug)
		d.Set("url", p.URL)
		d.Set("permalink", p.Permalink)
		d.Set("date", p.Date)
		d.Set("date_long", DateLong(p.Date))
		postLink[p] = d
	}

	postObj := make(map[*Post]*tmpl.Dict, len(s.Posts))
	v.posts = make([]tmpl.Value, len(s.Posts))
	for i, p := range s.Posts {
		d := tmpl.NewDict(11)
		d.Set("title", p.Title)
		d.Set("slug", p.Slug)
		d.Set("url", p.URL)
		d.Set("permalink", p.Permalink)
		d.Set("date", p.Date)
		d.Set("date_long", DateLong(p.Date))
		tags := make([]tmpl.Value, len(p.Tags))
		for j, t := range p.Tags {
			tags[j] = tagLink[t]
		}
		d.Set("tags", tags)
		d.Set("content", p.Content)
		d.Set("excerpt", p.Excerpt)
		d.Set("older", neighbour(postLink, p.Older))
		d.Set("newer", neighbour(postLink, p.Newer))
		postObj[p] = d
		v.posts[i] = d
	}

	v.tagFull = make([]tmpl.Value, len(s.Tags))
	for i, t := range s.Tags {
		d := tmpl.NewDict(5)
		d.Set("name", t.Name)
		d.Set("slug", t.Slug)
		d.Set("url", t.URL)
		d.Set("post_count", int64(len(t.Posts)))
		posts := make([]tmpl.Value, len(t.Posts))
		for j, p := range t.Posts {
			posts[j] = postObj[p]
		}
		d.Set("posts", posts)
		v.tagFull[i] = d
	}

	v.pages = make([]tmpl.Value, len(s.Pages))
	v.pageFull = make([]tmpl.Value, len(s.Pages))
	for i, pg := range s.Pages {
		l := tmpl.NewDict(3)
		l.Set("title", pg.Title)
		l.Set("slug", pg.Slug)
		l.Set("url", pg.URL)
		v.pages[i] = l
		d := tmpl.NewDict(5)
		d.Set("title", pg.Title)
		d.Set("slug", pg.Slug)
		d.Set("url", pg.URL)
		d.Set("permalink", pg.Permalink)
		d.Set("content", pg.Content)
		v.pageFull[i] = d
	}
	return v
}

func neighbour(links map[*Post]*tmpl.Dict, p *Post) tmpl.Value {
	if p == nil {
		return tmpl.None
	}
	return links[p]
}

// indexURL is the URL of index page n (1-based).
func indexURL(n int) string {
	if n == 1 {
		return "/"
	}
	return "/page/" + strconv.Itoa(n) + "/"
}

// pagination builds the pagination object of index page n.
func (s *Site) pagination(n int) *tmpl.Dict {
	total := s.TotalPages()
	d := tmpl.NewDict(8)
	d.Set("number", int64(n))
	d.Set("total_pages", int64(total))
	d.Set("total_posts", int64(len(s.Posts)))
	d.Set("has_prev", n > 1)
	d.Set("has_next", n < total)
	if n > 1 {
		d.Set("prev_url", indexURL(n-1))
	} else {
		d.Set("prev_url", tmpl.None)
	}
	if n < total {
		d.Set("next_url", indexURL(n+1))
	} else {
		d.Set("next_url", tmpl.None)
	}
	links := make([]tmpl.Value, total)
	for i := range links {
		l := tmpl.NewDict(3)
		l.Set("number", int64(i+1))
		l.Set("url", indexURL(i+1))
		l.Set("current", i+1 == n)
		links[i] = l
	}
	d.Set("links", links)
	return d
}
