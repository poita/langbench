//! End-to-end tests: build whole sites in temporary directories.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

/// A temporary directory removed on drop.
struct Tmp(PathBuf);

impl Tmp {
    fn new(label: &str) -> Tmp {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "sitegen-test-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
            label
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Tmp(dir)
    }
    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn write(root: &Path, rel: &str, contents: impl AsRef<[u8]>) {
    let p = root.join(rel);
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, contents).unwrap();
}

/// Every file below `root`, as relative path -> bytes.
fn read_tree(root: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(dir: &Path, prefix: &str, out: &mut BTreeMap<String, Vec<u8>>) {
        for e in fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let name = format!("{}{}", prefix, e.file_name().to_string_lossy());
            if e.path().is_dir() {
                walk(&e.path(), &format!("{}/", name), out);
            } else {
                out.insert(name, fs::read(e.path()).unwrap());
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, "", &mut out);
    out
}

fn text(tree: &BTreeMap<String, Vec<u8>>, path: &str) -> String {
    String::from_utf8(
        tree.get(path)
            .unwrap_or_else(|| panic!("missing {}", path))
            .clone(),
    )
    .unwrap()
}

/// Trivial templates that print just enough to observe the model.
fn plain_templates(root: &Path) {
    write(root, "templates/index.html", "I{{ pagination.number }}/{{ pagination.total_pages }}:{% for p in posts %}{{ p.slug }},{% endfor %}");
    write(root, "templates/post.html", "P:{{ post.slug }}");
    write(root, "templates/page.html", "G:{{ page.slug }}");
    write(
        root,
        "templates/tag.html",
        "T:{{ tag.slug }}:{{ tag.post_count }}",
    );
    write(
        root,
        "templates/tags.html",
        "TAGS:{% for t in tags %}{{ t.slug }},{% endfor %}",
    );
}

fn site_toml(root: &Path, per_page: usize) {
    write(
        root,
        "site.toml",
        format!(
            "title = \"T\"\nbase_url = \"https://x.test\"\nauthor = \"A\"\nposts_per_page = {}\n",
            per_page
        ),
    );
}

fn post(root: &Path, file: &str, front: &str, body: &str) {
    write(
        root,
        &format!("content/posts/{}", file),
        format!("+++\n{}\n+++\n{}", front, body),
    );
}

fn generate(input: &Path) -> BTreeMap<String, Vec<u8>> {
    let out = input.join("_out");
    sitegen::generate(input, &out).unwrap();
    read_tree(&out)
}

// ---- the worked example of the specification --------------------------------

fn pond(root: &Path) {
    write(root, "site.toml", "title = \"Pond Notes\"\nbase_url = \"https://pond.example\"\nauthor = \"R. Duck\"\nposts_per_page = 1\n");
    write(root, "content/posts/hello-world.md", "+++\ntitle = \"Hello, world\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\nThe **first** post.\n\nMore text.\n");
    write(root, "content/posts/on-ducks.md", "+++\ntitle = \"On Ducks\"\ndate = \"2024-02-01\"\ntags = [\"Birds\", \"Meta\"]\nslug = \"ducks\"\n+++\nDucks are *fine*.\n");
    write(
        root,
        "content/pages/about.md",
        "+++\ntitle = \"About\"\n+++\n# About\n\nNothing here.\n",
    );
    write(root, "templates/base.html", "<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n{% block body %}{% endblock %}\n");
    write(root, "templates/index.html", "{% extends \"base.html\" %}\n{% block body %}{% for post in posts %}<h2><a href=\"{{ post.url }}\">{{ post.title }}</a></h2>\n{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>\n{% if pagination.has_next %}<a href=\"{{ pagination.next_url }}\">older</a>{% endif %}{% endblock %}\n");
    write(root, "templates/post.html", "{% extends \"base.html\" %}\n{% block title %}{{ post.title }} \u{b7} {{ site.title }}{% endblock %}\n{% block body %}<article>\n{{ post.content }}</article>\n<p>{{ post.date_long }}{% for t in post.tags %} <a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}</p>\n{% if post.older %}<a href=\"{{ post.older.url }}\">{{ post.older.title }}</a>{% endif %}{% endblock %}\n");
    write(root, "templates/page.html", "{% extends \"base.html\" %}\n{% block title %}{{ page.title }}{% endblock %}\n{% block body %}{{ page.content }}{% endblock %}\n");
    write(root, "templates/tag.html", "{% extends \"base.html\" %}\n{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}\n");
    write(root, "templates/tags.html", "{% extends \"base.html\" %}\n{% block body %}<ul>{% for t in tags %}<li><a href=\"{{ t.url }}\">{{ t.name }}</a> {{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}\n");
    write(root, "static/robots.txt", "User-agent: *\n");
}

#[test]
fn worked_example_from_the_specification() {
    let tmp = Tmp::new("pond");
    pond(tmp.path());
    let tree = generate(tmp.path());

    let paths: Vec<&str> = tree.keys().map(|s| s.as_str()).collect();
    assert_eq!(
        paths,
        [
            "about/index.html",
            "feed.xml",
            "index.html",
            "page/2/index.html",
            "posts/ducks/index.html",
            "posts/hello-world/index.html",
            "robots.txt",
            "sitemap.xml",
            "tags/birds/index.html",
            "tags/index.html",
            "tags/meta/index.html",
        ]
    );

    assert_eq!(
        text(&tree, "index.html"),
        "<!doctype html>\n<title>Pond Notes</title>\n<h2><a href=\"/posts/ducks/\">On Ducks</a></h2>\n<p>Ducks are <em>fine</em>.</p>\n<p>page 1 of 2</p>\n<a href=\"/page/2/\">older</a>"
    );
    assert_eq!(
        text(&tree, "posts/ducks/index.html"),
        "<!doctype html>\n<title>On Ducks \u{b7} Pond Notes</title>\n<article>\n<p>Ducks are <em>fine</em>.</p>\n</article>\n<p>February 1, 2024 <a href=\"/tags/birds/\">Birds</a> <a href=\"/tags/meta/\">Meta</a></p>\n<a href=\"/posts/hello-world/\">Hello, world</a>"
    );
    assert_eq!(
        text(&tree, "tags/index.html"),
        "<!doctype html>\n<title>Pond Notes</title>\n<ul><li><a href=\"/tags/birds/\">Birds</a> 1</li><li><a href=\"/tags/meta/\">Meta</a> 2</li></ul>"
    );
    assert_eq!(
        text(&tree, "feed.xml"),
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>
<feed xmlns=\"http://www.w3.org/2005/Atom\">
  <title>Pond Notes</title>
  <id>https://pond.example/</id>
  <updated>2024-02-01T00:00:00Z</updated>
  <link href=\"https://pond.example/\" rel=\"alternate\"/>
  <link href=\"https://pond.example/feed.xml\" rel=\"self\"/>
  <author>
    <name>R. Duck</name>
  </author>
  <entry>
    <title>On Ducks</title>
    <id>https://pond.example/posts/ducks/</id>
    <updated>2024-02-01T00:00:00Z</updated>
    <link href=\"https://pond.example/posts/ducks/\" rel=\"alternate\"/>
    <content type=\"html\">&lt;p&gt;Ducks are &lt;em&gt;fine&lt;/em&gt;.&lt;/p&gt;
</content>
  </entry>
</feed>
"
    );
    assert_eq!(
        text(&tree, "sitemap.xml"),
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>
<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">
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
"
    );
    assert_eq!(text(&tree, "robots.txt"), "User-agent: *\n");
}

// ---- model ---------------------------------------------------------------------

#[test]
fn drafts_are_excluded_everywhere() {
    let tmp = Tmp::new("drafts");
    let r = tmp.path();
    site_toml(r, 10);
    plain_templates(r);
    post(
        r,
        "live.md",
        "title = \"Live\"\ndate = \"2024-01-01\"\ntags = [\"kept\"]",
        "x\n",
    );
    post(
        r,
        "wip.md",
        "title = \"WIP\"\ndate = \"2025-01-01\"\ntags = [\"kept\", \"only-draft\"]\ndraft = true",
        "x\n",
    );
    write(
        r,
        "content/pages/secret.md",
        "+++\ntitle = \"S\"\ndraft = true\n+++\n",
    );
    write(r, "content/pages/open.md", "+++\ntitle = \"O\"\n+++\n");
    let tree = generate(r);
    assert!(!tree.contains_key("posts/wip/index.html"));
    assert!(!tree.contains_key("secret/index.html"));
    assert!(!tree.contains_key("tags/only-draft/index.html"));
    assert_eq!(text(&tree, "index.html"), "I1/1:live,");
    assert_eq!(text(&tree, "tags/index.html"), "TAGS:kept,");
    assert_eq!(text(&tree, "tags/kept/index.html"), "T:kept:1");
    let feed = text(&tree, "feed.xml");
    assert!(feed.contains("<updated>2024-01-01T00:00:00Z</updated>"));
    assert!(!feed.contains("WIP"));
    assert!(!text(&tree, "sitemap.xml").contains("wip"));
}

#[test]
fn canonical_order_date_descending_then_slug() {
    let tmp = Tmp::new("order");
    let r = tmp.path();
    site_toml(r, 10);
    plain_templates(r);
    post(r, "b.md", "title = \"b\"\ndate = \"2024-05-01\"", "");
    post(r, "a.md", "title = \"a\"\ndate = \"2024-05-01\"", "");
    post(r, "c.md", "title = \"c\"\ndate = \"2024-06-01\"", "");
    post(
        r,
        "old.md",
        "title = \"o\"\ndate = \"2023-12-31\"\nslug = \"z-old\"",
        "",
    );
    let tree = generate(r);
    assert_eq!(text(&tree, "index.html"), "I1/1:c,a,b,z-old,");
}

#[test]
fn tags_are_deduplicated_slugged_and_ordered_by_slug() {
    let tmp = Tmp::new("tags");
    let r = tmp.path();
    site_toml(r, 10);
    plain_templates(r);
    write(
        r,
        "templates/post.html",
        "{% for t in post.tags %}{{ t.name }}={{ t.slug }}({{ t.post_count }}) {% endfor %}",
    );
    post(r, "one.md", "title = \"1\"\ndate = \"2024-01-02\"\ntags = [\"Web Development\", \"C++\", \"Web Development\", \"Go\"]", "");
    post(
        r,
        "two.md",
        "title = \"2\"\ndate = \"2024-01-01\"\ntags = [\"Rust 2024\", \"C++\"]",
        "",
    );
    let tree = generate(r);
    // Ordered by slug, not by name; a repeated tag within a post counts once.
    assert_eq!(
        text(&tree, "tags/index.html"),
        "TAGS:c,go,rust-2024,web-development,"
    );
    assert_eq!(
        text(&tree, "posts/one/index.html"),
        "Web Development=web-development(1) C++=c(2) Go=go(1) "
    );
    assert_eq!(text(&tree, "tags/c/index.html"), "T:c:2");
}

#[test]
fn older_and_newer_are_site_wide_neighbours() {
    let tmp = Tmp::new("neighbours");
    let r = tmp.path();
    site_toml(r, 1);
    plain_templates(r);
    write(r, "templates/tag.html", "{% for p in posts %}{{ p.slug }}:{{ p.newer.slug|default('-') }}:{{ p.older.slug|default('-') }};{% endfor %}");
    write(r, "templates/index.html", "{% for p in posts %}{{ p.slug }}:{% if p.newer %}N{% else %}-{% endif %}:{% if p.older %}O{% else %}-{% endif %}{% endfor %}");
    post(
        r,
        "p1.md",
        "title = \"1\"\ndate = \"2024-01-01\"\ntags = [\"t\"]",
        "",
    );
    post(r, "p2.md", "title = \"2\"\ndate = \"2024-01-02\"", "");
    post(
        r,
        "p3.md",
        "title = \"3\"\ndate = \"2024-01-03\"\ntags = [\"t\"]",
        "",
    );
    let tree = generate(r);
    // p2 is not in the tag, but is still the neighbour of p1 and p3.
    assert_eq!(text(&tree, "tags/t/index.html"), "p3:-:p2;p1:p2:-;");
    assert_eq!(text(&tree, "index.html"), "p3:-:O");
    assert_eq!(text(&tree, "page/3/index.html"), "p1:N:-");
}

#[test]
fn excerpt_is_the_first_block_cut_textually() {
    let tmp = Tmp::new("excerpt");
    let r = tmp.path();
    site_toml(r, 10);
    plain_templates(r);
    write(
        r,
        "templates/index.html",
        "{% for p in posts %}[{{ p.excerpt }}]{% endfor %}",
    );
    post(
        r,
        "a.md",
        "title = \"a\"\ndate = \"2024-01-05\"",
        "\n  \nFirst para\nstill first\n\nSecond\n",
    );
    post(
        r,
        "b.md",
        "title = \"b\"\ndate = \"2024-01-04\"",
        "# Heading\nnext line\n",
    );
    post(
        r,
        "c.md",
        "title = \"c\"\ndate = \"2024-01-03\"",
        "```\ncode\n\nmore\n```\n",
    );
    post(r, "d.md", "title = \"d\"\ndate = \"2024-01-02\"", "\n\n");
    let tree = generate(r);
    assert_eq!(
        text(&tree, "index.html"),
        "[<p>First para\nstill first</p>\n][<h1>Heading</h1>\n<p>next line</p>\n][<pre><code>code\n</code></pre>\n][]"
    );
}

#[test]
fn site_toml_values_reach_templates_in_file_order() {
    let tmp = Tmp::new("site-values");
    let r = tmp.path();
    write(r, "site.toml", "title = \"T\"\nbase_url = \"https://x.test\"\nauthor = \"A\"\nposts_per_page = 2\nmotto = \"a\\nb\"\nflag = true\nnum = -3\nlist = [\"p\", \"q\"]\n");
    plain_templates(r);
    write(r, "templates/index.html", "{% for k in site %}{{ k }},{% endfor %}|{{ site.flag }}{{ site.num }}{{ site.list|join('+') }}{{ site.motto|length }}");
    let tree = generate(r);
    assert_eq!(
        text(&tree, "index.html"),
        "title,base_url,author,posts_per_page,motto,flag,num,list,|True-3p+q3"
    );
}

// ---- pagination -------------------------------------------------------------

fn paginated(n_posts: usize, per_page: usize) -> BTreeMap<String, Vec<u8>> {
    let tmp = Tmp::new("pagination");
    let r = tmp.path();
    site_toml(r, per_page);
    plain_templates(r);
    write(
        r,
        "templates/index.html",
        "{{ pagination.number }}/{{ pagination.total_pages }}/{{ pagination.total_posts }} prev={{ pagination.prev_url }} next={{ pagination.next_url }} {{ pagination.has_prev }}{{ pagination.has_next }} [{% for l in pagination.links %}{{ l.number }}={{ l.url }}{% if l.current %}*{% endif %} {% endfor %}] n={{ posts|length }}",
    );
    for i in 0..n_posts {
        post(
            r,
            &format!("p{:03}.md", i),
            &format!("title = \"P{}\"\ndate = \"2024-01-{:02}\"", i, i % 28 + 1),
            "",
        );
    }
    generate(r)
}

#[test]
fn pagination_exact_multiple() {
    let tree = paginated(4, 2);
    assert_eq!(
        text(&tree, "index.html"),
        "1/2/4 prev=None next=/page/2/ FalseTrue [1=/* 2=/page/2/ ] n=2"
    );
    assert_eq!(
        text(&tree, "page/2/index.html"),
        "2/2/4 prev=/ next=None TrueFalse [1=/ 2=/page/2/* ] n=2"
    );
    assert!(!tree.contains_key("page/3/index.html"));
}

#[test]
fn pagination_remainder_on_last_page() {
    let tree = paginated(5, 2);
    assert!(text(&tree, "page/3/index.html").ends_with("n=1"));
    assert!(text(&tree, "page/2/index.html").starts_with("2/3/5 prev=/ next=/page/3/ "));
}

#[test]
fn site_without_posts_has_one_index_page() {
    let tree = paginated(0, 3);
    assert_eq!(
        text(&tree, "index.html"),
        "1/1/0 prev=None next=None FalseFalse [1=/* ] n=0"
    );
    assert!(!tree.contains_key("page/2/index.html"));
    let feed = text(&tree, "feed.xml");
    assert!(feed.contains("<updated>1970-01-01T00:00:00Z</updated>"));
    assert!(feed.ends_with("  </author>\n</feed>\n"));
}

#[test]
fn posts_per_page_larger_than_post_count() {
    let tree = paginated(3, 50);
    assert!(text(&tree, "index.html").starts_with("1/1/3 "));
}

// ---- feed and sitemap -------------------------------------------------------

#[test]
fn feed_escapes_and_is_limited_to_one_page_of_posts() {
    let tmp = Tmp::new("feed");
    let r = tmp.path();
    write(r, "site.toml", "title = \"A & B <c>\"\nbase_url = \"https://x.test/blog\"\nauthor = \"Q \\\"R\\\"\"\nposts_per_page = 2\n");
    plain_templates(r);
    post(
        r,
        "a.md",
        "title = \"T1 & <x>\"\ndate = \"2024-01-03\"",
        "5 > 3 & \"q\" 'a'\n",
    );
    post(r, "b.md", "title = \"T2\"\ndate = \"2024-01-02\"", "b\n");
    post(r, "c.md", "title = \"T3\"\ndate = \"2024-01-01\"", "c\n");
    let tree = generate(r);
    let feed = text(&tree, "feed.xml");
    assert!(feed.contains("  <title>A &amp; B &lt;c&gt;</title>\n"));
    assert!(feed.contains("  <id>https://x.test/blog/</id>\n"));
    assert!(feed.contains("<link href=\"https://x.test/blog/feed.xml\" rel=\"self\"/>"));
    assert!(feed.contains("    <name>Q \"R\"</name>\n"));
    assert!(feed.contains("    <title>T1 &amp; &lt;x&gt;</title>\n"));
    assert!(feed.contains(
        "&lt;p&gt;5 &amp;gt; 3 &amp;amp; &amp;quot;q&amp;quot; 'a'&lt;/p&gt;\n</content>"
    ));
    assert_eq!(feed.matches("<entry>").count(), 2);
    assert!(!feed.contains("T3"));
    let sitemap = text(&tree, "sitemap.xml");
    assert_eq!(sitemap.matches("<lastmod>").count(), 3);
    assert!(sitemap.contains("<loc>https://x.test/blog/posts/c/</loc>"));
}

// ---- static files and the output layout --------------------------------------------

#[test]
fn static_files_are_copied_byte_for_byte() {
    let tmp = Tmp::new("static");
    let r = tmp.path();
    site_toml(r, 5);
    plain_templates(r);
    let binary: Vec<u8> = (0..=255u8).chain([0, 0, 13, 10]).collect();
    write(r, "static/css/site.css", "body { color: red }\r\n");
    write(r, "static/img/logo.bin", &binary);
    write(r, "static/.well-known/security.txt", "hi");
    write(r, "static/.hidden", "dot");
    write(r, "static/empty.txt", "");
    write(r, "static/a/b/c/d.txt", "deep");
    fs::create_dir_all(r.join("static/empty-dir")).unwrap();
    let tree = generate(r);
    assert_eq!(tree["css/site.css"], b"body { color: red }\r\n");
    assert_eq!(tree["img/logo.bin"], binary);
    assert_eq!(tree[".well-known/security.txt"], b"hi");
    assert_eq!(tree[".hidden"], b"dot");
    assert_eq!(tree["empty.txt"], b"");
    assert_eq!(tree["a/b/c/d.txt"], b"deep");
    assert!(!tree.keys().any(|k| k.contains("empty-dir")));
}

#[test]
fn missing_content_directories_and_unused_templates_are_fine() {
    let tmp = Tmp::new("minimal");
    let r = tmp.path();
    site_toml(r, 5);
    plain_templates(r);
    write(r, "templates/never-used.html", "{% this is not valid");
    let tree = generate(r);
    let paths: Vec<&str> = tree.keys().map(|s| s.as_str()).collect();
    assert_eq!(
        paths,
        ["feed.xml", "index.html", "sitemap.xml", "tags/index.html"]
    );
}

#[test]
fn template_source_loses_exactly_one_trailing_newline() {
    let tmp = Tmp::new("trailing-newline");
    let r = tmp.path();
    site_toml(r, 5);
    plain_templates(r);
    write(r, "templates/index.html", "line\n\n");
    write(r, "templates/tags.html", "x\n");
    let tree = generate(r);
    assert_eq!(text(&tree, "index.html"), "line\n");
    assert_eq!(text(&tree, "tags/index.html"), "x");
}

#[test]
fn front_matter_strings_with_delimiters_and_escapes() {
    let tmp = Tmp::new("front-matter");
    let r = tmp.path();
    site_toml(r, 5);
    plain_templates(r);
    write(
        r,
        "templates/post.html",
        "{{ post.title }}|{{ post.content }}",
    );
    write(
        r,
        "content/posts/x.md",
        "+++\ntitle = \"+++ \\\"q\\\" \\u00e9 # not a comment\"  # real comment\ndate = \"2024-03-05\"\n+++\n+++\nbody\n",
    );
    let tree = generate(r);
    assert_eq!(
        text(&tree, "posts/x/index.html"),
        "+++ \"q\" \u{e9} # not a comment|<p>+++\nbody</p>\n"
    );
}

#[test]
fn template_errors_are_reported_with_the_page() {
    let tmp = Tmp::new("errors");
    let r = tmp.path();
    site_toml(r, 5);
    plain_templates(r);
    write(r, "templates/post.html", "{{ post.nope }}");
    post(r, "a.md", "title = \"a\"\ndate = \"2024-01-01\"", "");
    let err = sitegen::generate(r, &r.join("_out")).unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("posts/a/index.html") && msg.contains("post.html"),
        "{}",
        msg
    );
    assert!(matches!(err, sitegen::Error::Template { .. }));
}

#[test]
fn missing_site_toml_is_an_io_error() {
    let tmp = Tmp::new("no-config");
    let err = sitegen::generate(tmp.path(), &tmp.path().join("out")).unwrap_err();
    assert!(matches!(err, sitegen::Error::Io { .. }));
}

// ---- the command-line tool ----------------------------------------------------------

#[test]
fn cli_builds_a_site() {
    let tmp = Tmp::new("cli");
    let input = tmp.path().join("in");
    pond(&input);
    let out = tmp.path().join("out");
    fs::create_dir_all(&out).unwrap();
    let status = Command::new(env!("CARGO_BIN_EXE_sitegen"))
        .arg(&input)
        .arg(&out)
        .status()
        .unwrap();
    assert!(status.success());
    let tree = read_tree(&out);
    assert_eq!(tree.len(), 11);
    assert!(text(&tree, "index.html").contains("page 1 of 2"));
}

#[test]
fn cli_creates_a_missing_output_directory() {
    let tmp = Tmp::new("cli-mkdir");
    let input = tmp.path().join("in");
    pond(&input);
    let out = tmp.path().join("does/not/exist");
    let status = Command::new(env!("CARGO_BIN_EXE_sitegen"))
        .arg(&input)
        .arg(&out)
        .status()
        .unwrap();
    assert!(status.success());
    assert!(out.join("index.html").is_file());
}

#[test]
fn cli_reports_errors_with_a_nonzero_exit_code() {
    let tmp = Tmp::new("cli-error");
    let status = Command::new(env!("CARGO_BIN_EXE_sitegen"))
        .arg(tmp.path().join("missing"))
        .arg(tmp.path().join("out"))
        .output()
        .unwrap();
    assert_eq!(status.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&status.stderr).contains("sitegen:"));
}

#[test]
fn cli_usage_error() {
    let out = Command::new(env!("CARGO_BIN_EXE_sitegen"))
        .arg("only-one")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("usage:"));
}
