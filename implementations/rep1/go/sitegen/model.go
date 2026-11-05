package sitegen

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Post is a published (or draft) post.
type Post struct {
	Title    string
	Slug     string
	Date     string // YYYY-MM-DD
	Tags     []string
	Draft    bool
	Body     string // Markdown source
	URL      string // /posts/<slug>/
	DateLong string // e.g. "March 5, 2024"
}

// Page is a standalone page.
type Page struct {
	Title string
	Slug  string
	Draft bool
	Body  string // Markdown source
	URL   string // /<slug>/
}

// Tag is a tag together with the published posts that carry it.
type Tag struct {
	Name  string
	Slug  string
	URL   string // /tags/<slug>/
	Posts []*Post
}

var monthNames = [...]string{
	"January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December",
}

// LongDate renders a YYYY-MM-DD date as "<Month> <D>, <YYYY>". It returns an
// error if date is not of that form.
func LongDate(date string) (string, error) {
	if len(date) != 10 || date[4] != '-' || date[7] != '-' {
		return "", fmt.Errorf("invalid date %q: want YYYY-MM-DD", date)
	}
	for i := 0; i < len(date); i++ {
		if i != 4 && i != 7 && (date[i] < '0' || date[i] > '9') {
			return "", fmt.Errorf("invalid date %q: want YYYY-MM-DD", date)
		}
	}
	month, _ := strconv.Atoi(date[5:7])
	day, _ := strconv.Atoi(date[8:10])
	if month < 1 || month > 12 {
		return "", fmt.Errorf("invalid date %q: month out of range", date)
	}
	return fmt.Sprintf("%s %d, %s", monthNames[month-1], day, date[:4]), nil
}

// TagSlug derives the slug of a tag name: ASCII letters are lower-cased,
// every other character that is not a letter or digit becomes '-', runs of
// '-' collapse to one, and leading and trailing '-' are removed.
func TagSlug(name string) string {
	var sb strings.Builder
	dash := false
	for _, r := range name {
		switch {
		case r >= 'A' && r <= 'Z':
			r += 'a' - 'A'
			fallthrough
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			sb.WriteRune(r)
			dash = false
		default:
			if !dash && sb.Len() > 0 {
				sb.WriteByte('-')
			}
			dash = true
		}
	}
	return strings.TrimSuffix(sb.String(), "-")
}

// sortPosts orders posts canonically: date descending, then slug ascending.
func sortPosts(posts []*Post) {
	sort.SliceStable(posts, func(i, j int) bool {
		if posts[i].Date != posts[j].Date {
			return posts[i].Date > posts[j].Date
		}
		return posts[i].Slug < posts[j].Slug
	})
}

// sortPages orders pages by slug.
func sortPages(pages []*Page) {
	sort.SliceStable(pages, func(i, j int) bool { return pages[i].Slug < pages[j].Slug })
}

// collectTags gathers the tags of posts, which must be in canonical order.
// Repeated tag names within a post are dropped (keeping the first); each
// tag's posts come out in canonical order; tags are sorted by slug. The
// returned posts have their Tags de-duplicated.
func collectTags(posts []*Post) []*Tag {
	byName := map[string]*Tag{}
	var tags []*Tag
	for _, p := range posts {
		seen := make(map[string]bool, len(p.Tags))
		uniq := p.Tags[:0:0]
		for _, name := range p.Tags {
			if seen[name] {
				continue
			}
			seen[name] = true
			uniq = append(uniq, name)
			t := byName[name]
			if t == nil {
				slug := TagSlug(name)
				t = &Tag{Name: name, Slug: slug, URL: "/tags/" + slug + "/"}
				byName[name] = t
				tags = append(tags, t)
			}
			t.Posts = append(t.Posts, p)
		}
		p.Tags = uniq
	}
	sort.SliceStable(tags, func(i, j int) bool { return tags[i].Slug < tags[j].Slug })
	return tags
}

// totalPages returns the number of index pages for n posts.
func totalPages(n, perPage int) int {
	if n <= 0 {
		return 1
	}
	return (n + perPage - 1) / perPage
}

// indexURL returns the URL of index page number n (1-based).
func indexURL(n int) string {
	if n == 1 {
		return "/"
	}
	return "/page/" + strconv.Itoa(n) + "/"
}
