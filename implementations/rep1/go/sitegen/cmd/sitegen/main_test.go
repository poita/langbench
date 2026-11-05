package main

import (
	"os"
	"path/filepath"
	"testing"
)

func write(t *testing.T, root, name, content string) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRun(t *testing.T) {
	in := t.TempDir()
	write(t, in, "site.toml", "title = \"T\"\nbase_url = \"https://x.test\"\nauthor = \"A\"\nposts_per_page = 5\n")
	write(t, in, "content/posts/hi.md", "+++\ntitle = \"Hi\"\ndate = \"2024-01-02\"\ntags = [\"a b\"]\n+++\nHello *world*.\n")
	write(t, in, "templates/index.html", "{% for p in posts %}{{ p.excerpt }}{% endfor %}")
	write(t, in, "templates/post.html", "{{ post.content }}")
	write(t, in, "templates/page.html", "{{ page.content }}")
	write(t, in, "templates/tag.html", "{{ tag.name }}")
	write(t, in, "templates/tags.html", "{{ tags|length }}")
	write(t, in, "static/css/site.css", "body{}")

	out := filepath.Join(t.TempDir(), "out") // does not exist yet: run creates it
	if err := run(in, out); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"index.html":          "<p>Hello <em>world</em>.</p>\n",
		"posts/hi/index.html": "<p>Hello <em>world</em>.</p>\n",
		"tags/index.html":     "1",
		"tags/a-b/index.html": "a b",
		"css/site.css":        "body{}",
	}
	for name, content := range want {
		got, err := os.ReadFile(filepath.Join(out, filepath.FromSlash(name)))
		if err != nil || string(got) != content {
			t.Errorf("%s = %q, %v; want %q", name, got, err, content)
		}
	}
	for _, name := range []string{"feed.xml", "sitemap.xml"} {
		if _, err := os.Stat(filepath.Join(out, name)); err != nil {
			t.Error(err)
		}
	}
}

func TestRunErrors(t *testing.T) {
	if err := run(filepath.Join(t.TempDir(), "missing"), t.TempDir()); err == nil {
		t.Error("expected an error for a missing input directory")
	}
	in := t.TempDir()
	write(t, in, "site.toml", "title = 1\n")
	if err := run(in, t.TempDir()); err == nil {
		t.Error("expected an error for an invalid site.toml")
	}
}
