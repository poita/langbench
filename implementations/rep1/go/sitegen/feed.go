package sitegen

import "strings"

// xmlText escapes s for use as XML character data.
func xmlText(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	return strings.ReplaceAll(s, ">", "&gt;")
}

// xmlAttr escapes s for use inside a double-quoted XML attribute.
func xmlAttr(s string) string {
	return strings.ReplaceAll(xmlText(s), `"`, "&quot;")
}

// Feed renders the Atom feed of the site: the newest PostsPerPage posts, in
// canonical order. The feed's update time is the date of the newest post (or
// the epoch for a site without posts), so the output never depends on the
// clock.
func (s *Site) Feed() string {
	var b strings.Builder
	updated := "1970-01-01T00:00:00Z"
	if len(s.Posts) > 0 {
		updated = s.Posts[0].Date + "T00:00:00Z"
	}
	home := s.BaseURL + "/"
	b.WriteString("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
	b.WriteString("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n")
	b.WriteString("  <title>" + xmlText(s.Title) + "</title>\n")
	b.WriteString("  <id>" + xmlText(home) + "</id>\n")
	b.WriteString("  <updated>" + updated + "</updated>\n")
	b.WriteString("  <link href=\"" + xmlAttr(home) + "\" rel=\"alternate\"/>\n")
	b.WriteString("  <link href=\"" + xmlAttr(s.BaseURL+"/feed.xml") + "\" rel=\"self\"/>\n")
	b.WriteString("  <author>\n")
	b.WriteString("    <name>" + xmlText(s.Author) + "</name>\n")
	b.WriteString("  </author>\n")
	for _, p := range s.Posts[:min(len(s.Posts), s.PostsPerPage)] {
		b.WriteString("  <entry>\n")
		b.WriteString("    <title>" + xmlText(p.Title) + "</title>\n")
		b.WriteString("    <id>" + xmlText(p.Permalink) + "</id>\n")
		b.WriteString("    <updated>" + p.Date + "T00:00:00Z</updated>\n")
		b.WriteString("    <link href=\"" + xmlAttr(p.Permalink) + "\" rel=\"alternate\"/>\n")
		b.WriteString("    <content type=\"html\">" + xmlText(p.Content) + "</content>\n")
		b.WriteString("  </entry>\n")
	}
	b.WriteString("</feed>\n")
	return b.String()
}

// Sitemap renders sitemap.xml: the index pages, the posts (with their dates
// as lastmod), the pages, the tag index and the tags, in that order.
func (s *Site) Sitemap() string {
	var b strings.Builder
	url := func(loc, lastmod string) {
		b.WriteString("  <url>\n")
		b.WriteString("    <loc>" + xmlText(loc) + "</loc>\n")
		if lastmod != "" {
			b.WriteString("    <lastmod>" + lastmod + "</lastmod>\n")
		}
		b.WriteString("  </url>\n")
	}
	b.WriteString("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
	b.WriteString("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n")
	for n := 1; n <= s.TotalPages(); n++ {
		url(s.BaseURL+indexURL(n), "")
	}
	for _, p := range s.Posts {
		url(p.Permalink, p.Date)
	}
	for _, pg := range s.Pages {
		url(pg.Permalink, "")
	}
	url(s.BaseURL+"/tags/", "")
	for _, t := range s.Tags {
		url(s.BaseURL+t.URL, "")
	}
	b.WriteString("</urlset>\n")
	return b.String()
}
