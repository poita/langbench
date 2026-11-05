package sitegen

import "strings"

const epoch = "1970-01-01T00:00:00Z"

// feed renders the Atom feed: one entry for each of the first
// posts_per_page published posts. contents holds the HTML of each post,
// parallel to s.Posts.
func (s *Site) feed(contents []string) []byte {
	cfg := &s.Config
	var sb strings.Builder
	updated := epoch
	if len(s.Posts) > 0 {
		updated = s.Posts[0].Date + "T00:00:00Z"
	}
	sb.WriteString("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
	sb.WriteString("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n")
	sb.WriteString("  <title>")
	escapeText(&sb, cfg.Title)
	sb.WriteString("</title>\n  <id>")
	escapeText(&sb, cfg.BaseURL+"/")
	sb.WriteString("</id>\n  <updated>" + updated + "</updated>\n")
	sb.WriteString("  <link href=\"")
	escapeAttr(&sb, cfg.BaseURL+"/")
	sb.WriteString("\" rel=\"alternate\"/>\n  <link href=\"")
	escapeAttr(&sb, cfg.BaseURL+"/feed.xml")
	sb.WriteString("\" rel=\"self\"/>\n  <author>\n    <name>")
	escapeText(&sb, cfg.Author)
	sb.WriteString("</name>\n  </author>\n")
	n := len(s.Posts)
	if n > cfg.PostsPerPage {
		n = cfg.PostsPerPage
	}
	for i := 0; i < n; i++ {
		p := s.Posts[i]
		permalink := cfg.BaseURL + p.URL
		sb.WriteString("  <entry>\n    <title>")
		escapeText(&sb, p.Title)
		sb.WriteString("</title>\n    <id>")
		escapeText(&sb, permalink)
		sb.WriteString("</id>\n    <updated>" + p.Date + "T00:00:00Z</updated>\n    <link href=\"")
		escapeAttr(&sb, permalink)
		sb.WriteString("\" rel=\"alternate\"/>\n    <content type=\"html\">")
		escapeText(&sb, contents[i])
		sb.WriteString("</content>\n  </entry>\n")
	}
	sb.WriteString("</feed>\n")
	return []byte(sb.String())
}

// sitemap renders sitemap.xml: the index pages, the posts (with lastmod),
// the pages, the tag index and every tag.
func (s *Site) sitemap(totalPages int) []byte {
	base := s.Config.BaseURL
	var sb strings.Builder
	sb.WriteString("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
	sb.WriteString("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n")
	url := func(loc, lastmod string) {
		sb.WriteString("  <url>\n    <loc>")
		escapeText(&sb, loc)
		sb.WriteString("</loc>\n")
		if lastmod != "" {
			sb.WriteString("    <lastmod>" + lastmod + "</lastmod>\n")
		}
		sb.WriteString("  </url>\n")
	}
	for n := 1; n <= totalPages; n++ {
		url(base+indexURL(n), "")
	}
	for _, p := range s.Posts {
		url(base+p.URL, p.Date)
	}
	for _, p := range s.Pages {
		url(base+p.URL, "")
	}
	url(base+"/tags/", "")
	for _, t := range s.Tags {
		url(base+t.URL, "")
	}
	sb.WriteString("</urlset>\n")
	return []byte(sb.String())
}
