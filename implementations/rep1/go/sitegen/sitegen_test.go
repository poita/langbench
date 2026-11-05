package sitegen

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/fstest"
)

// pondSite is the worked example of the specification.
func pondSite() fstest.MapFS {
	return fstest.MapFS{
		"site.toml":                    {Data: []byte("title = \"Pond Notes\"\nbase_url = \"https://pond.example\"\nauthor = \"R. Duck\"\nposts_per_page = 1\n")},
		"content/posts/hello-world.md": {Data: []byte("+++\ntitle = \"Hello, world\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\nThe **first** post.\n\nMore text.\n")},
		"content/posts/on-ducks.md":    {Data: []byte("+++\ntitle = \"On Ducks\"\ndate = \"2024-02-01\"\ntags = [\"Birds\", \"Meta\"]\nslug = \"ducks\"\n+++\nDucks are *fine*.\n")},
		"content/pages/about.md":       {Data: []byte("+++\ntitle = \"About\"\n+++\n# About\n\nNothing here.\n")},
		"templates/base.html":          {Data: []byte("<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n{% block body %}{% endblock %}\n")},
		"templates/index.html":         {Data: []byte("{% extends \"base.html\" %}\n{% block body %}{% for post in posts %}<h2><a href=\"{{ post.url }}\">{{ post.title }}</a></h2>\n{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>\n{% if pagination.has_next %}<a href=\"{{ pagination.next_url }}\">older</a>{% endif %}{% endblock %}\n")},
		"templates/post.html":          {Data: []byte("{% extends \"base.html\" %}\n{% block title %}{{ post.title }} · {{ site.title }}{% endblock %}\n{% block body %}<article>\n{{ post.content }}</article>\n<p>{{ post.date_long }}{% for t in post.tags %} <a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}</p>\n{% if post.older %}<a href=\"{{ post.older.url }}\">{{ post.older.title }}</a>{% endif %}{% endblock %}\n")},
		"templates/page.html":          {Data: []byte("{% extends \"base.html\" %}\n{% block title %}{{ page.title }}{% endblock %}\n{% block body %}{{ page.content }}{% endblock %}\n")},
		"templates/tag.html":           {Data: []byte("{% extends \"base.html\" %}\n{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}\n")},
		"templates/tags.html":          {Data: []byte("{% extends \"base.html\" %}\n{% block body %}<ul>{% for t in tags %}<li><a href=\"{{ t.url }}\">{{ t.name }}</a> {{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}\n")},
		"static/robots.txt":            {Data: []byte("User-agent: *\n")},
	}
}

func fileMap(t *testing.T, o *Output) map[string]string {
	t.Helper()
	m := map[string]string{}
	for _, f := range o.Files {
		if _, dup := m[f.Path]; dup {
			t.Errorf("duplicate output path %s", f.Path)
		}
		m[f.Path] = string(f.Data)
	}
	return m
}

func TestWorkedExample(t *testing.T) {
	out, err := Build(pondSite())
	if err != nil {
		t.Fatal(err)
	}
	files := fileMap(t, out)
	want := map[string]string{
		"index.html":             "<!doctype html>\n<title>Pond Notes</title>\n<h2><a href=\"/posts/ducks/\">On Ducks</a></h2>\n<p>Ducks are <em>fine</em>.</p>\n<p>page 1 of 2</p>\n<a href=\"/page/2/\">older</a>",
		"posts/ducks/index.html": "<!doctype html>\n<title>On Ducks · Pond Notes</title>\n<article>\n<p>Ducks are <em>fine</em>.</p>\n</article>\n<p>February 1, 2024 <a href=\"/tags/birds/\">Birds</a> <a href=\"/tags/meta/\">Meta</a></p>\n<a href=\"/posts/hello-world/\">Hello, world</a>",
		"tags/index.html":        "<!doctype html>\n<title>Pond Notes</title>\n<ul><li><a href=\"/tags/birds/\">Birds</a> 1</li><li><a href=\"/tags/meta/\">Meta</a> 2</li></ul>",
		"feed.xml": `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Pond Notes</title>
  <id>https://pond.example/</id>
  <updated>2024-02-01T00:00:00Z</updated>
  <link href="https://pond.example/" rel="alternate"/>
  <link href="https://pond.example/feed.xml" rel="self"/>
  <author>
    <name>R. Duck</name>
  </author>
  <entry>
    <title>On Ducks</title>
    <id>https://pond.example/posts/ducks/</id>
    <updated>2024-02-01T00:00:00Z</updated>
    <link href="https://pond.example/posts/ducks/" rel="alternate"/>
    <content type="html">&lt;p&gt;Ducks are &lt;em&gt;fine&lt;/em&gt;.&lt;/p&gt;
</content>
  </entry>
</feed>
`,
		"sitemap.xml": `<?xml version="1.0" encoding="utf-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>https://pond.example/</loc>
  </url>
  <url>
    <loc>https://pond.example/page/2/</loc>
  </url>
  <url>
    <loc>https://pond.example/posts/ducks/</loc>
    <lastmod>2024-02-01</lastmod>
  </url>
  <url>
    <loc>https://pond.example/posts/hello-world/</loc>
    <lastmod>2024-01-10</lastmod>
  </url>
  <url>
    <loc>https://pond.example/about/</loc>
  </url>
  <url>
    <loc>https://pond.example/tags/</loc>
  </url>
  <url>
    <loc>https://pond.example/tags/birds/</loc>
  </url>
  <url>
    <loc>https://pond.example/tags/meta/</loc>
  </url>
</urlset>
`,
		"robots.txt": "User-agent: *\n",
	}
	for p, w := range want {
		if got, ok := files[p]; !ok {
			t.Errorf("missing %s", p)
		} else if got != w {
			t.Errorf("%s:\n got: %q\nwant: %q", p, got, w)
		}
	}
	paths := []string{"index.html", "page/2/index.html", "posts/ducks/index.html", "posts/hello-world/index.html",
		"about/index.html", "tags/index.html", "tags/birds/index.html", "tags/meta/index.html", "feed.xml", "sitemap.xml", "robots.txt"}
	if got := out.Paths(); !reflect.DeepEqual(got, paths) {
		t.Errorf("paths = %v\nwant    %v", got, paths)
	}
}

func TestTagSlug(t *testing.T) {
	tests := map[string]string{
		"Web Development": "web-development", "C++": "c", "Rust 2024": "rust-2024", "  lead": "lead",
		"trail  ": "trail", "a--b": "a-b", "A/B\\C": "a-b-c", "Ünï": "n", "x_y": "x-y", "-": "", "9": "9", "日本": "",
	}
	for in, want := range tests {
		if got := TagSlug(in); got != want {
			t.Errorf("TagSlug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLongDate(t *testing.T) {
	tests := map[string]string{"2024-03-05": "March 5, 2024", "1999-12-25": "December 25, 1999", "2000-01-01": "January 1, 2000", "0042-07-31": "July 31, 0042"}
	for in, want := range tests {
		if got, err := LongDate(in); err != nil || got != want {
			t.Errorf("LongDate(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "2024-3-5", "2024/03/05", "2024-13-01", "abcd-ef-gh", "2024-00-10"} {
		if _, err := LongDate(bad); err == nil {
			t.Errorf("LongDate(%q): expected an error", bad)
		}
	}
}

func TestSplitFrontMatter(t *testing.T) {
	tests := []struct{ in, front, body string }{
		{"+++\na = 1\n+++\nbody\n", "a = 1\n", "body\n"},
		{"+++\n+++\n", "", ""},
		{"+++\na = 1\n+++", "a = 1\n", ""},
		{"+++\nt = \"+++ x\"\n++++\n +++\n+++\n+++\ntext", "t = \"+++ x\"\n++++\n +++\n", "+++\ntext"},
		{"+++\na = 1\n+++\n\n\nbody", "a = 1\n", "\n\nbody"},
	}
	for _, tc := range tests {
		front, body, err := splitFrontMatter(tc.in)
		if err != nil || front != tc.front || body != tc.body {
			t.Errorf("splitFrontMatter(%q) = %q, %q, %v", tc.in, front, body, err)
		}
	}
	for _, bad := range []string{"", "no front matter", "++\n+++\n", "+++ \na\n+++\n", "+++\na = 1\n", "+++\na = 1\n+++ \n"} {
		if _, _, err := splitFrontMatter(bad); err == nil {
			t.Errorf("splitFrontMatter(%q): expected an error", bad)
		}
	}
}

func TestFirstBlock(t *testing.T) {
	tests := map[string]string{
		"":                           "",
		"\n  \t\n":                   "",
		"one\ntwo\n\nthree":          "one\ntwo",
		"\n\n  \nfirst\n \nsecond":   "first",
		"```\ncode\n\nmore\n```":     "```\ncode",
		"# Title\nafter heading\n\n": "# Title\nafter heading",
		"single":                     "single",
	}
	for in, want := range tests {
		if got := firstBlock(in); got != want {
			t.Errorf("firstBlock(%q) = %q, want %q", in, got, want)
		}
	}
}

// siteWith returns a minimal site whose templates print the values under test.
func siteWith(posts map[string]string, indexTpl string) fstest.MapFS {
	fsys := fstest.MapFS{
		"site.toml":            {Data: []byte("title = \"T\"\nbase_url = \"http://x.test\"\nauthor = \"A\"\nposts_per_page = 2\nextra = [\"p\", \"q\"]\nflag = true\nnum = 7\n")},
		"templates/index.html": {Data: []byte(indexTpl)},
		"templates/post.html":  {Data: []byte("{{ post.title }}|{{ post.date }}|{{ post.older.slug|default('-') }}|{{ post.newer.slug|default('-') }}|{{ post.tags|length }}")},
		"templates/page.html":  {Data: []byte("{{ page.title }}")},
		"templates/tag.html":   {Data: []byte("{{ tag.name }}:{{ tag.post_count }}:{% for p in posts %}{{ p.slug }},{% endfor %}")},
		"templates/tags.html":  {Data: []byte("{% for t in tags %}{{ t.slug }}={{ t.post_count }};{% endfor %}")},
	}
	for name, content := range posts {
		fsys["content/posts/"+name] = &fstest.MapFile{Data: []byte(content)}
	}
	return fsys
}

func post(title, date string, extra string) string {
	return "+++\ntitle = \"" + title + "\"\ndate = \"" + date + "\"\n" + extra + "+++\nbody of " + title + "\n"
}

func TestOrderingDraftsAndTags(t *testing.T) {
	fsys := siteWith(map[string]string{
		"b.md":     post("B", "2024-05-01", "tags = [\"Go\", \"Go\", \"go lang\"]\n"),
		"a.md":     post("A", "2024-05-01", "tags = [\"Go\"]\n"),
		"c.md":     post("C", "2024-06-01", ""),
		"old.md":   post("Old", "2023-01-01", "tags = [\"Zed\"]\n"),
		"draft.md": post("Draft", "2025-01-01", "draft = true\ntags = [\"Only Draft\"]\n"),
	}, "{% for p in posts %}{{ p.slug }}{% if not loop.last %},{% endif %}{% endfor %}")
	out, err := Build(fsys)
	if err != nil {
		t.Fatal(err)
	}
	files := fileMap(t, out)
	if files["index.html"] != "c,a" || files["page/2/index.html"] != "b,old" {
		t.Errorf("index pages: %q / %q", files["index.html"], files["page/2/index.html"])
	}
	if _, ok := files["posts/draft/index.html"]; ok {
		t.Error("draft post was rendered")
	}
	if _, ok := files["tags/only-draft/index.html"]; ok {
		t.Error("tag of a draft post exists")
	}
	if got := files["posts/b/index.html"]; got != "B|2024-05-01|old|a|2" {
		t.Errorf("post b = %q", got)
	}
	if got := files["posts/c/index.html"]; got != "C|2024-06-01|a|-|0" {
		t.Errorf("post c = %q", got)
	}
	if got := files["tags/index.html"]; got != "go=2;go-lang=1;zed=1;" {
		t.Errorf("tags index = %q", got)
	}
	if got := files["tags/go/index.html"]; got != "Go:2:a,b," {
		t.Errorf("tag go = %q", got)
	}
	if strings.Contains(files["sitemap.xml"], "draft") {
		t.Error("draft in sitemap")
	}
}

func TestNoPosts(t *testing.T) {
	fsys := siteWith(nil, "n={{ posts|length }} t={{ pagination.total_pages }} {{ pagination.has_prev }} {{ pagination.prev_url }} {{ pagination.next_url }} {{ pagination.links|length }} {{ site.extra|join('+') }} {{ site.flag }} {{ site.num + 1 }}")
	out, err := Build(fsys)
	if err != nil {
		t.Fatal(err)
	}
	files := fileMap(t, out)
	if files["index.html"] != "n=0 t=1 False None None 1 p+q True 8" {
		t.Errorf("index = %q", files["index.html"])
	}
	if !strings.Contains(files["feed.xml"], "<updated>1970-01-01T00:00:00Z</updated>") ||
		!strings.HasSuffix(files["feed.xml"], "  </author>\n</feed>\n") {
		t.Errorf("empty feed = %q", files["feed.xml"])
	}
	if _, ok := files["page/2/index.html"]; ok {
		t.Error("unexpected second index page")
	}
}

func TestPaginationValues(t *testing.T) {
	posts := map[string]string{}
	for i, d := range []string{"01", "02", "03", "04", "05"} {
		posts["p"+d+".md"] = post("P"+d, "2024-01-"+d, "")
		_ = i
	}
	tpl := "{{ pagination.number }}/{{ pagination.total_pages }}/{{ pagination.total_posts }} prev={{ pagination.prev_url }} next={{ pagination.next_url }} " +
		"{% for l in pagination.links %}{% if l.current %}[{{ l.number }}]{% else %}{{ l.url }}{% endif %} {% endfor %}"
	out, err := Build(siteWith(posts, tpl))
	if err != nil {
		t.Fatal(err)
	}
	files := fileMap(t, out)
	want := map[string]string{
		"index.html":        "1/3/5 prev=None next=/page/2/ [1] /page/2/ /page/3/ ",
		"page/2/index.html": "2/3/5 prev=/ next=/page/3/ / [2] /page/3/ ",
		"page/3/index.html": "3/3/5 prev=/page/2/ next=None / /page/2/ [3] ",
	}
	for p, w := range want {
		if files[p] != w {
			t.Errorf("%s = %q, want %q", p, files[p], w)
		}
	}
}

func TestPagesAndStatic(t *testing.T) {
	fsys := siteWith(nil, "{% for p in pages %}{{ p.slug }}:{{ p.url }};{% endfor %}")
	fsys["content/pages/zeta.md"] = &fstest.MapFile{Data: []byte("+++\ntitle = \"Z\"\n+++\n")}
	fsys["content/pages/alpha-page.md"] = &fstest.MapFile{Data: []byte("+++\ntitle = \"A\"\nslug = \"alpha\"\n+++\ntext\n")}
	fsys["content/pages/hidden.md"] = &fstest.MapFile{Data: []byte("+++\ntitle = \"H\"\ndraft = true\n+++\n")}
	fsys["content/pages/notes.txt"] = &fstest.MapFile{Data: []byte("ignored")}
	fsys["static/.hidden/.dot"] = &fstest.MapFile{Data: []byte("dot")}
	fsys["static/img/a.bin"] = &fstest.MapFile{Data: []byte{0, 1, 2, 0xff}}
	fsys["static/empty.txt"] = &fstest.MapFile{}
	out, err := Build(fsys)
	if err != nil {
		t.Fatal(err)
	}
	files := fileMap(t, out)
	if files["index.html"] != "alpha:/alpha/;zeta:/zeta/;" {
		t.Errorf("pages = %q", files["index.html"])
	}
	for p, w := range map[string]string{".hidden/.dot": "dot", "img/a.bin": "\x00\x01\x02\xff", "empty.txt": "", "alpha/index.html": "A", "zeta/index.html": "Z"} {
		if got, ok := files[p]; !ok || got != w {
			t.Errorf("%s = %q (present %v), want %q", p, got, ok, w)
		}
	}
	if _, ok := files["hidden/index.html"]; ok {
		t.Error("draft page rendered")
	}
	if _, ok := files["notes.txt"]; ok {
		t.Error("non-.md file used")
	}
}

func TestMarkdownAndEscapingInFeed(t *testing.T) {
	fsys := siteWith(map[string]string{"x.md": post("Q&A <\\\"1\\\"> 'x'", "2024-01-01", "") + "\n`a<b` & [l](/u?a=1&b=2)\n"}, "")
	fsys["site.toml"] = &fstest.MapFile{Data: []byte("title = \"A & B <C>\"\nbase_url = \"http://x.test/a\\\"b\"\nauthor = \"O'Neil\"\nposts_per_page = 5\n")}
	out, err := Build(fsys)
	if err != nil {
		t.Fatal(err)
	}
	feed := fileMap(t, out)["feed.xml"]
	for _, want := range []string{
		"<title>A &amp; B &lt;C&gt;</title>",
		"<id>http://x.test/a\"b/</id>",
		"<link href=\"http://x.test/a&quot;b/\" rel=\"alternate\"/>",
		"<name>O'Neil</name>",
		"<title>Q&amp;A &lt;\"1\"&gt; 'x'</title>",
		"&lt;p&gt;body of Q&amp;amp;A",
		"&lt;code&gt;a&amp;lt;b&lt;/code&gt;",
	} {
		if !strings.Contains(feed, want) {
			t.Errorf("feed lacks %q:\n%s", want, feed)
		}
	}
}

func TestLoadErrors(t *testing.T) {
	good := func() fstest.MapFS { return siteWith(nil, "x") }
	tests := map[string]func(fstest.MapFS){
		"missing site.toml": func(f fstest.MapFS) { delete(f, "site.toml") },
		"bad site.toml":     func(f fstest.MapFS) { f["site.toml"] = &fstest.MapFile{Data: []byte("title = 1")} },
		"bad posts_per_page": func(f fstest.MapFS) {
			f["site.toml"] = &fstest.MapFile{Data: []byte("title=\"a\"\nbase_url=\"b\"\nauthor=\"c\"\nposts_per_page=0")}
		},
		"missing template": func(f fstest.MapFS) { delete(f, "templates/tag.html") },
		"bad front matter": func(f fstest.MapFS) { f["content/posts/x.md"] = &fstest.MapFile{Data: []byte("no front matter")} },
		"missing title": func(f fstest.MapFS) {
			f["content/posts/x.md"] = &fstest.MapFile{Data: []byte("+++\ndate = \"2024-01-01\"\n+++\n")}
		},
		"bad date": func(f fstest.MapFS) {
			f["content/posts/x.md"] = &fstest.MapFile{Data: []byte("+++\ntitle=\"x\"\ndate = \"soon\"\n+++\n")}
		},
		"bad page": func(f fstest.MapFS) { f["content/pages/x.md"] = &fstest.MapFile{Data: []byte("+++\ndraft = 1\n+++\n")} },
	}
	for name, mutate := range tests {
		f := good()
		mutate(f)
		if _, err := Load(f); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	// A template error surfaces from Generate with the output path.
	f := good()
	f["templates/tags.html"] = &fstest.MapFile{Data: []byte("{{ nope }}")}
	if _, err := Build(f); err == nil || !strings.Contains(err.Error(), "tags/index.html") {
		t.Errorf("template error = %v", err)
	}
}

func TestWriteDir(t *testing.T) {
	out, err := Build(pondSite())
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(t.TempDir(), "public")
	if err := out.WriteDir(dir); err != nil {
		t.Fatal(err)
	}
	for _, f := range out.Files {
		got, err := os.ReadFile(filepath.Join(dir, filepath.FromSlash(f.Path)))
		if err != nil || string(got) != string(f.Data) {
			t.Errorf("%s: %v", f.Path, err)
		}
	}
	bad := &Output{Files: []File{{Path: "../escape.txt", Data: []byte("x")}}}
	if err := bad.WriteDir(dir); err == nil {
		t.Error("expected an error for a path escaping the output directory")
	}
}

func TestBuildDir(t *testing.T) {
	dir := t.TempDir()
	for name, f := range pondSite() {
		full := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, f.Data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	out, err := BuildDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Files) != 11 {
		t.Errorf("got %d files", len(out.Files))
	}
}
