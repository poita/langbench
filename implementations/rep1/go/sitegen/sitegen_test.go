package sitegen_test

import (
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"testing/fstest"

	"example.com/sitegen"
)

// TestWorkedExample generates the worked example of the specification
// (testdata/pond) and compares every file.
func TestWorkedExample(t *testing.T) {
	sink := sitegen.MemSink{}
	if err := sitegen.Build(os.DirFS("testdata/pond"), sink); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"index.html": `<!doctype html>
<title>Pond Notes</title>
<h2><a href="/posts/ducks/">On Ducks</a></h2>
<p>Ducks are <em>fine</em>.</p>
<p>page 1 of 2</p>
<a href="/page/2/">older</a>`,
		"page/2/index.html": `<!doctype html>
<title>Pond Notes</title>
<h2><a href="/posts/hello-world/">Hello, world</a></h2>
<p>The <strong>first</strong> post.</p>
<p>page 2 of 2</p>
`,
		"posts/ducks/index.html": `<!doctype html>
<title>On Ducks · Pond Notes</title>
<article>
<p>Ducks are <em>fine</em>.</p>
</article>
<p>February 1, 2024 <a href="/tags/birds/">Birds</a> <a href="/tags/meta/">Meta</a></p>
<a href="/posts/hello-world/">Hello, world</a>`,
		"posts/hello-world/index.html": `<!doctype html>
<title>Hello, world · Pond Notes</title>
<article>
<p>The <strong>first</strong> post.</p>
<p>More text.</p>
</article>
<p>January 10, 2024 <a href="/tags/meta/">Meta</a></p>
`,
		"about/index.html": `<!doctype html>
<title>About</title>
<h1>About</h1>
<p>Nothing here.</p>
`,
		"tags/index.html": `<!doctype html>
<title>Pond Notes</title>
<ul><li><a href="/tags/birds/">Birds</a> 1</li><li><a href="/tags/meta/">Meta</a> 2</li></ul>`,
		"tags/birds/index.html": `<!doctype html>
<title>Pond Notes</title>
<h1>Birds (1)</h1>
<ul><li>On Ducks</li></ul>`,
		"tags/meta/index.html": `<!doctype html>
<title>Pond Notes</title>
<h1>Meta (2)</h1>
<ul><li>On Ducks</li><li>Hello, world</li></ul>`,
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
	var gotNames, wantNames []string
	for name := range sink {
		gotNames = append(gotNames, name)
	}
	for name := range want {
		wantNames = append(wantNames, name)
	}
	sort.Strings(gotNames)
	sort.Strings(wantNames)
	if !reflect.DeepEqual(gotNames, wantNames) {
		t.Fatalf("files = %q, want %q", gotNames, wantNames)
	}
	for name, w := range want {
		if got := string(sink[name]); got != w {
			t.Errorf("%s:\n got: %q\nwant: %q", name, got, w)
		}
	}
}

func TestTagSlug(t *testing.T) {
	for in, want := range map[string]string{
		"Web Development": "web-development",
		"C++":             "c",
		"Rust 2024":       "rust-2024",
		"  --a--b--  ":    "a-b",
		"ÀB":              "b",
		"a/b_c":           "a-b-c",
		"":                "",
		"already-slug":    "already-slug",
	} {
		if got := sitegen.TagSlug(in); got != want {
			t.Errorf("TagSlug(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDateLong(t *testing.T) {
	for in, want := range map[string]string{
		"2024-03-05": "March 5, 2024",
		"1999-12-25": "December 25, 1999",
		"2000-01-31": "January 31, 2000",
		"0999-02-10": "February 10, 0999",
		"garbage":    "garbage",
	} {
		if got := sitegen.DateLong(in); got != want {
			t.Errorf("DateLong(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSplitFrontMatter(t *testing.T) {
	tests := []struct {
		in, front, body string
		ok              bool
	}{
		{"+++\na = 1\n+++\nbody\n", "a = 1\n", "body\n", true},
		{"+++\n+++\n", "", "", true},
		{"+++\n+++", "", "", true},
		{"+++\na = \"+++\"\n++++\n +++\n+++\nx\n+++\n", "a = \"+++\"\n++++\n +++\n", "x\n+++\n", true},
		{"+++\na = 1\n+++", "a = 1\n", "", true},
		{"+++\na = 1\n", "", "", false},
		{"a = 1\n+++\n", "", "", false},
		{"++\n", "", "", false},
	}
	for _, tc := range tests {
		front, body, err := sitegen.SplitFrontMatter(tc.in)
		if (err == nil) != tc.ok || front != tc.front || body != tc.body {
			t.Errorf("SplitFrontMatter(%q) = %q, %q, %v", tc.in, front, body, err)
		}
	}
}

// site builds an in-memory source with the five required templates, which
// print enough to observe the context, plus the given files.
func site(posts_per_page string, files map[string]string) fstest.MapFS {
	m := fstest.MapFS{
		"site.toml":            {Data: []byte("title = \"T\"\nbase_url = \"https://x.test/b\"\nauthor = \"A\"\nposts_per_page = " + posts_per_page + "\nextra = [\"p\", \"q\"]\n")},
		"templates/index.html": {Data: []byte(`{% for p in posts %}{{ p.slug }}({{ p.older.slug|default("-") }},{{ p.newer.slug|default("-") }}) {% endfor %}| {{ pagination.number }}/{{ pagination.total_pages }} {{ pagination.total_posts }} {{ pagination.has_prev }} {{ pagination.has_next }} {{ pagination.prev_url }} {{ pagination.next_url }} {% for l in pagination.links %}{{ l.number }}{{ l.url }}{{ l.current }} {% endfor %}|{{ tags|length }} {{ pages|length }} {{ site.extra|join("+") }}`)},
		"templates/post.html":  {Data: []byte("{{ post.title }}|{{ post.url }}|{{ post.permalink }}|{{ post.date_long }}|{% for t in post.tags %}{{ t.name }}={{ t.slug }}:{{ t.post_count }},{% endfor %}")},
		"templates/page.html":  {Data: []byte("{{ page.title }}|{{ page.url }}|{{ page.permalink }}")},
		"templates/tag.html":   {Data: []byte("{{ tag.name }}:{{ tag.post_count }}:{% for p in posts %}{{ p.slug }},{% endfor %}:{{ tag.posts|length }}")},
		"templates/tags.html":  {Data: []byte("{% for t in tags %}{{ t.slug }},{% endfor %}")},
	}
	for name, data := range files {
		m[name] = &fstest.MapFile{Data: []byte(data)}
	}
	return m
}

func post(title, date, extra string) string {
	return "+++\ntitle = \"" + title + "\"\ndate = \"" + date + "\"\n" + extra + "+++\nBody of " + title + ".\n\nMore.\n"
}

func generate(t *testing.T, fsys fs.FS) sitegen.MemSink {
	t.Helper()
	sink := sitegen.MemSink{}
	if err := sitegen.Build(fsys, sink); err != nil {
		t.Fatal(err)
	}
	return sink
}

func TestOrderingAndNavigation(t *testing.T) {
	fsys := site("2", map[string]string{
		"content/posts/b.md":        post("B", "2024-01-01", "tags = [\"Zed\", \"Alpha\", \"Zed\"]\n"),
		"content/posts/a.md":        post("A", "2024-01-01", "tags = [\"Alpha\"]\n"),
		"content/posts/new.md":      post("New", "2024-05-05", ""),
		"content/posts/old.md":      post("Old", "2023-12-31", "slug = \"zz\"\ntags = [\"Zed\"]\n"),
		"content/posts/d.md":        post("Draft", "2025-01-01", "draft = true\ntags = [\"Secret\"]\n"),
		"content/pages/zeta.md":     "+++\ntitle = \"Z\"\n+++\nz\n",
		"content/pages/beta.md":     "+++\ntitle = \"B\"\nslug = \"alpha\"\n+++\nb\n",
		"content/pages/hid.md":      "+++\ntitle = \"H\"\ndraft = true\n+++\nh\n",
		"content/posts/ignored.txt": "not content",
	})
	out := generate(t, fsys)

	wantFiles := []string{
		"alpha/index.html", "feed.xml", "index.html", "page/2/index.html", "posts/a/index.html",
		"posts/b/index.html", "posts/new/index.html", "posts/zz/index.html", "sitemap.xml",
		"tags/alpha/index.html", "tags/index.html", "tags/zed/index.html", "zeta/index.html",
	}
	var got []string
	for name := range out {
		got = append(got, name)
	}
	sort.Strings(got)
	if !reflect.DeepEqual(got, wantFiles) {
		t.Fatalf("files:\n got %q\nwant %q", got, wantFiles)
	}
	check := func(name, want string) {
		t.Helper()
		if g := string(out[name]); g != want {
			t.Errorf("%s:\n got: %q\nwant: %q", name, g, want)
		}
	}
	// Canonical order: New, then the two 2024-01-01 posts by slug (a, b), then zz.
	check("index.html", "new(a,-) a(b,new) | 1/2 4 False True None /page/2/ 1/True 2/page/2/False |2 2 p+q")
	check("page/2/index.html", "b(zz,a) zz(-,b) | 2/2 4 True False / None 1/False 2/page/2/True |2 2 p+q")
	check("posts/b/index.html", "B|/posts/b/|https://x.test/b/posts/b/|January 1, 2024|Zed=zed:2,Alpha=alpha:2,")
	check("alpha/index.html", "B|/alpha/|https://x.test/b/alpha/")
	check("tags/index.html", "alpha,zed,")
	check("tags/alpha/index.html", "Alpha:2:a,b,:2")
	check("tags/zed/index.html", "Zed:2:b,zz,:2")
}

func TestNoPosts(t *testing.T) {
	out := generate(t, site("3", nil))
	if got, want := string(out["index.html"]), "| 1/1 0 False False None None 1/True |0 0 p+q"; got != want {
		t.Errorf("index.html = %q, want %q", got, want)
	}
	if _, ok := out["page/2/index.html"]; ok {
		t.Error("unexpected page/2")
	}
	wantFeed := `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>T</title>
  <id>https://x.test/b/</id>
  <updated>1970-01-01T00:00:00Z</updated>
  <link href="https://x.test/b/" rel="alternate"/>
  <link href="https://x.test/b/feed.xml" rel="self"/>
  <author>
    <name>A</name>
  </author>
</feed>
`
	if got := string(out["feed.xml"]); got != wantFeed {
		t.Errorf("feed.xml = %q", got)
	}
	if got := string(out["tags/index.html"]); got != "" {
		t.Errorf("tags/index.html = %q", got)
	}
	if !strings.Contains(string(out["sitemap.xml"]), "<loc>https://x.test/b/tags/</loc>") {
		t.Error("sitemap lacks the tag index")
	}
}

func TestExcerptAndEscaping(t *testing.T) {
	fsys := site("5", map[string]string{
		"templates/index.html": "{% for p in posts %}[{{ p.excerpt }}]{% endfor %}",
		"content/posts/a.md":   "+++\ntitle = \"A & <B> \\\"q\\\" 'x'\"\ndate = \"2024-01-01\"\n+++\n\n  \n# Head\ntext\n\npara 2\n",
		"content/posts/b.md":   "+++\ntitle = \"B\"\ndate = \"2024-01-02\"\n+++\n```\ncode\n\nmore\n```\n",
		"content/posts/c.md":   "+++\ntitle = \"C\"\ndate = \"2024-01-03\"\n+++\n \n\t\n",
	})
	out := generate(t, fsys)
	// An ATX heading and the text below it form one block of non-blank lines.
	want := "[]" + "[<pre><code>code\n</code></pre>\n]" + "[<h1>Head</h1>\n<p>text</p>\n]"
	if got := string(out["index.html"]); got != want {
		t.Errorf("index.html = %q, want %q", got, want)
	}
	feed := string(out["feed.xml"])
	if !strings.Contains(feed, "<title>A &amp; &lt;B&gt; \"q\" 'x'</title>") {
		t.Errorf("feed title not escaped as expected:\n%s", feed)
	}
	if !strings.Contains(feed, `<content type="html">&lt;h1&gt;Head&lt;/h1&gt;`) {
		t.Errorf("feed content not escaped:\n%s", feed)
	}
}

func TestStaticFiles(t *testing.T) {
	fsys := site("1", map[string]string{
		"static/css/site.css": "body{}",
		"static/.hidden/.dot": "dot",
		"static/empty":        "",
		"static/a/b/c/d.bin":  "\x00\x01\xff\r\n",
	})
	out := generate(t, fsys)
	for name, want := range map[string]string{
		"css/site.css": "body{}", ".hidden/.dot": "dot", "empty": "", "a/b/c/d.bin": "\x00\x01\xff\r\n",
	} {
		got, ok := out[name]
		if !ok || string(got) != want {
			t.Errorf("%s = %q, %v; want %q", name, got, ok, want)
		}
	}
}

func TestTemplateSourceDropsOneTrailingNewline(t *testing.T) {
	fsys := site("1", map[string]string{"templates/tags.html": "x\n\n"})
	if got := string(generate(t, fsys)["tags/index.html"]); got != "x\n" {
		t.Errorf("tags/index.html = %q, want %q", got, "x\n")
	}
}

func TestMarkdownBodyFidelity(t *testing.T) {
	fsys := site("1", map[string]string{
		"templates/post.html": "{{ post.content }}",
		"content/posts/p.md":  "+++\ntitle = \"P\"\ndate = \"2024-01-01\"\n+++\n+++\nnot a delimiter\n",
	})
	if got, want := string(generate(t, fsys)["posts/p/index.html"]), "<p>+++\nnot a delimiter</p>\n"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestErrors(t *testing.T) {
	tests := []struct {
		name  string
		fsys  fs.FS
		match string
	}{
		{"no site.toml", fstest.MapFS{}, "site.toml"},
		{"missing key", fstest.MapFS{"site.toml": {Data: []byte("title = \"x\"\n")}}, "base_url"},
		{"bad per page", fstest.MapFS{"site.toml": {Data: []byte("title=\"t\"\nbase_url=\"b\"\nauthor=\"a\"\nposts_per_page=0\n")}}, "posts_per_page"},
		{"bad toml", fstest.MapFS{"site.toml": {Data: []byte("title = ?\n")}}, "line 1"},
		{"post without date", site("1", map[string]string{"content/posts/a.md": "+++\ntitle = \"A\"\n+++\n"}), "date"},
		{"post without front matter", site("1", map[string]string{"content/posts/a.md": "hello\n"}), "content/posts/a.md"},
		{"broken template", site("1", map[string]string{"templates/tags.html": "{% if %}"}), "tags.html"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := sitegen.Build(tc.fsys, sitegen.MemSink{})
			if err == nil || !strings.Contains(err.Error(), tc.match) {
				t.Errorf("error = %v, want it to mention %q", err, tc.match)
			}
		})
	}
}

func TestDirSink(t *testing.T) {
	dir := t.TempDir()
	sink := sitegen.DirSink(dir)
	if err := sink.WriteFile("a/b/c.txt", []byte("hi")); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "a", "b", "c.txt"))
	if err != nil || string(b) != "hi" {
		t.Errorf("read back %q, %v", b, err)
	}
}

func TestLoadModel(t *testing.T) {
	s, err := sitegen.Load(os.DirFS("testdata/pond"))
	if err != nil {
		t.Fatal(err)
	}
	if s.TotalPages() != 2 || len(s.Posts) != 2 || len(s.Pages) != 1 || len(s.Tags) != 2 {
		t.Fatalf("model: %d pages, %d posts, %d pages, %d tags", s.TotalPages(), len(s.Posts), len(s.Pages), len(s.Tags))
	}
	p := s.Posts[0]
	if p.Slug != "ducks" || p.Older != s.Posts[1] || p.Newer != nil || s.Posts[1].Newer != p {
		t.Errorf("neighbours are wrong: %+v", p)
	}
	if s.Tags[1].Name != "Meta" || len(s.Tags[1].Posts) != 2 {
		t.Errorf("tags: %+v", s.Tags[1])
	}
}
