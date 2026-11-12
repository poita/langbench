#include <gtest/gtest.h>

#include <fstream>
#include <map>
#include <random>
#include <sstream>

#include "sitegen/sitegen.hpp"

using namespace sitegen;

namespace {

// The worked example of the specification.
SiteSource worked_example() {
  SiteSource s;
  s.config = toml::parse(
      "title = \"Pond Notes\"\nbase_url = \"https://pond.example\"\nauthor = \"R. Duck\"\nposts_per_page = 1\n");
  s.posts.push_back(parse_post("hello-world",
                               "+++\ntitle = \"Hello, world\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\n"
                               "The **first** post.\n\nMore text.\n"));
  s.posts.push_back(parse_post("on-ducks",
                               "+++\ntitle = \"On Ducks\"\ndate = \"2024-02-01\"\ntags = [\"Birds\", \"Meta\"]\n"
                               "slug = \"ducks\"\n+++\nDucks are *fine*.\n"));
  s.pages.push_back(parse_page("about", "+++\ntitle = \"About\"\n+++\n# About\n\nNothing here.\n"));
  s.templates = {
      {"base.html", "<!doctype html>\n<title>{% block title %}{{ site.title }}{% endblock %}</title>\n{% block body %}{% endblock %}"},
      {"index.html",
       "{% extends \"base.html\" %}\n{% block body %}{% for post in posts %}<h2><a href=\"{{ post.url }}\">{{ post.title }}</a></h2>\n"
       "{{ post.excerpt }}{% endfor %}<p>page {{ pagination.number }} of {{ pagination.total_pages }}</p>\n"
       "{% if pagination.has_next %}<a href=\"{{ pagination.next_url }}\">older</a>{% endif %}{% endblock %}"},
      {"post.html",
       "{% extends \"base.html\" %}\n{% block title %}{{ post.title }} \xC2\xB7 {{ site.title }}{% endblock %}\n"
       "{% block body %}<article>\n{{ post.content }}</article>\n"
       "<p>{{ post.date_long }}{% for t in post.tags %} <a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}</p>\n"
       "{% if post.older %}<a href=\"{{ post.older.url }}\">{{ post.older.title }}</a>{% endif %}{% endblock %}"},
      {"page.html",
       "{% extends \"base.html\" %}\n{% block title %}{{ page.title }}{% endblock %}\n{% block body %}{{ page.content }}{% endblock %}"},
      {"tag.html",
       "{% extends \"base.html\" %}\n{% block body %}<h1>{{ tag.name }} ({{ tag.post_count }})</h1>\n"
       "<ul>{% for post in posts %}<li>{{ post.title }}</li>{% endfor %}</ul>{% endblock %}"},
      {"tags.html",
       "{% extends \"base.html\" %}\n{% block body %}<ul>{% for t in tags %}<li><a href=\"{{ t.url }}\">{{ t.name }}</a> "
       "{{ t.post_count }}</li>{% endfor %}</ul>{% endblock %}"},
  };
  return s;
}

std::map<std::string, std::string> render_all(const SiteSource& src) {
  const SiteModel model = SiteModel::build(src);
  const TemplateEngine engine = make_template_engine(src);
  std::map<std::string, std::string> out;
  for (const OutputFile& f : render_site(model, engine)) out[f.path] = f.contents;
  return out;
}

}  // namespace

TEST(Generator, WorkedExampleProducesTheDocumentedFileSet) {
  const auto files = render_all(worked_example());
  std::vector<std::string> names;
  for (const auto& [name, contents] : files) names.push_back(name);
  EXPECT_EQ(names, (std::vector<std::string>{"about/index.html", "feed.xml", "index.html", "page/2/index.html",
                                             "posts/ducks/index.html", "posts/hello-world/index.html",
                                             "sitemap.xml", "tags/birds/index.html", "tags/index.html",
                                             "tags/meta/index.html"}));
}

TEST(Generator, WorkedExamplePages) {
  const auto files = render_all(worked_example());
  EXPECT_EQ(files.at("index.html"),
            "<!doctype html>\n<title>Pond Notes</title>\n<h2><a href=\"/posts/ducks/\">On Ducks</a></h2>\n"
            "<p>Ducks are <em>fine</em>.</p>\n<p>page 1 of 2</p>\n<a href=\"/page/2/\">older</a>");
  EXPECT_EQ(files.at("posts/ducks/index.html"),
            "<!doctype html>\n<title>On Ducks \xC2\xB7 Pond Notes</title>\n<article>\n<p>Ducks are <em>fine</em>.</p>\n"
            "</article>\n<p>February 1, 2024 <a href=\"/tags/birds/\">Birds</a> <a href=\"/tags/meta/\">Meta</a></p>\n"
            "<a href=\"/posts/hello-world/\">Hello, world</a>");
  EXPECT_EQ(files.at("tags/index.html"),
            "<!doctype html>\n<title>Pond Notes</title>\n<ul><li><a href=\"/tags/birds/\">Birds</a> 1</li>"
            "<li><a href=\"/tags/meta/\">Meta</a> 2</li></ul>");
  EXPECT_EQ(files.at("tags/meta/index.html"),
            "<!doctype html>\n<title>Pond Notes</title>\n<h1>Meta (2)</h1>\n<ul><li>On Ducks</li><li>Hello, world</li></ul>");
  EXPECT_EQ(files.at("about/index.html"),
            "<!doctype html>\n<title>About</title>\n<h1>About</h1>\n<p>Nothing here.</p>\n");
}

TEST(Generator, WorkedExampleFeed) {
  const auto files = render_all(worked_example());
  EXPECT_EQ(files.at("feed.xml"),
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n"
            "  <title>Pond Notes</title>\n"
            "  <id>https://pond.example/</id>\n"
            "  <updated>2024-02-01T00:00:00Z</updated>\n"
            "  <link href=\"https://pond.example/\" rel=\"alternate\"/>\n"
            "  <link href=\"https://pond.example/feed.xml\" rel=\"self\"/>\n"
            "  <author>\n    <name>R. Duck</name>\n  </author>\n"
            "  <entry>\n"
            "    <title>On Ducks</title>\n"
            "    <id>https://pond.example/posts/ducks/</id>\n"
            "    <updated>2024-02-01T00:00:00Z</updated>\n"
            "    <link href=\"https://pond.example/posts/ducks/\" rel=\"alternate\"/>\n"
            "    <content type=\"html\">&lt;p&gt;Ducks are &lt;em&gt;fine&lt;/em&gt;.&lt;/p&gt;\n"
            "</content>\n"
            "  </entry>\n"
            "</feed>\n");
}

TEST(Generator, WorkedExampleSitemap) {
  const auto files = render_all(worked_example());
  EXPECT_EQ(files.at("sitemap.xml"),
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
            "  <url>\n    <loc>https://pond.example/</loc>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/page/2/</loc>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/posts/ducks/</loc>\n    <lastmod>2024-02-01</lastmod>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/posts/hello-world/</loc>\n    <lastmod>2024-01-10</lastmod>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/about/</loc>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/tags/</loc>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/tags/birds/</loc>\n  </url>\n"
            "  <url>\n    <loc>https://pond.example/tags/meta/</loc>\n  </url>\n"
            "</urlset>\n");
}

TEST(Generator, EmptySiteHasDeterministicFeedAndOneIndexPage) {
  SiteSource s = worked_example();
  s.posts.clear();
  s.pages.clear();
  const auto files = render_all(s);
  EXPECT_EQ(files.count("page/2/index.html"), 0u);
  EXPECT_NE(files.at("feed.xml").find("<updated>1970-01-01T00:00:00Z</updated>"), std::string::npos);
  EXPECT_NE(files.at("feed.xml").find("  </author>\n</feed>\n"), std::string::npos);
  EXPECT_EQ(files.at("index.html"),
            "<!doctype html>\n<title>Pond Notes</title>\n<p>page 1 of 1</p>\n");
}

TEST(Generator, DraftsProduceNothing) {
  SiteSource s = worked_example();
  s.posts.push_back(parse_post("secret", "+++\ntitle = \"S\"\ndate = \"2030-01-01\"\ndraft = true\ntags = [\"hidden\"]\n+++\nx\n"));
  const auto files = render_all(s);
  EXPECT_EQ(files.count("posts/secret/index.html"), 0u);
  EXPECT_EQ(files.count("tags/hidden/index.html"), 0u);
  EXPECT_EQ(files.at("sitemap.xml").find("secret"), std::string::npos);
}

TEST(Generator, XmlEscaping) {
  EXPECT_EQ(xml_escape_text("a & b < c > d \" e ' f"), "a &amp; b &lt; c &gt; d \" e ' f");
  EXPECT_EQ(xml_escape_attribute("a \"q\" & <"), "a &quot;q&quot; &amp; &lt;");
  EXPECT_EQ(xml_escape_text("&amp;"), "&amp;amp;");
}

TEST(Generator, TemplateErrorsPropagate) {
  SiteSource s = worked_example();
  s.templates[1].second = "{{ nope }}";  // index.html
  EXPECT_THROW(render_all(s), TemplateError);
}

TEST(Generator, SuppliesExactlyTheDocumentedVariables) {
  SiteSource s = worked_example();
  s.templates = {{"index.html", "{{ post is defined }}{{ tag is defined }}{{ posts|length }}{{ pagination.total_posts }}"},
                 {"post.html", "{{ posts is defined }}{{ pagination is defined }}{{ post.slug }}"},
                 {"page.html", "{{ page.slug }}{{ post is defined }}"},
                 {"tag.html", "{{ tag.slug }}:{{ posts|length }}:{{ tag.posts|length }}"},
                 {"tags.html", "{{ tags|length }}{{ pages|length }}{{ site.title }}{{ posts is defined }}"}};
  const auto files = render_all(s);
  EXPECT_EQ(files.at("index.html"), "FalseFalse12");
  EXPECT_EQ(files.at("posts/ducks/index.html"), "FalseFalseducks");
  EXPECT_EQ(files.at("about/index.html"), "aboutFalse");
  EXPECT_EQ(files.at("tags/meta/index.html"), "meta:2:2");
  EXPECT_EQ(files.at("tags/index.html"), "21Pond NotesFalse");
}

namespace fs = std::filesystem;

namespace {

void write(const fs::path& p, const std::string& data) {
  fs::create_directories(p.parent_path());
  std::ofstream(p, std::ios::binary) << data;
}

std::string slurp(const fs::path& p) {
  std::ifstream in(p, std::ios::binary);
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

struct TempDir {
  fs::path path;
  TempDir() {
    path = fs::temp_directory_path() / ("sitegen_test_" + std::to_string(std::random_device{}()));
    fs::create_directories(path);
  }
  ~TempDir() {
    std::error_code ec;
    fs::remove_all(path, ec);
  }
};

}  // namespace

TEST(GenerateSite, EndToEndOnDisk) {
  TempDir tmp;
  const fs::path in = tmp.path / "in", out = tmp.path / "out";
  write(in / "site.toml", "title = \"T\"\nbase_url = \"https://x.org/blog\"\nauthor = \"Me\"\nposts_per_page = 2\n");
  write(in / "content/posts/first.md", "+++\ntitle = \"First\"\ndate = \"2024-05-06\"\ntags = [\"C++\"]\n+++\nHello\n");
  write(in / "content/posts/ignored.txt", "not markdown");
  write(in / "content/pages/about.md", "+++\ntitle = \"About\"\n+++\nAbout *me*\n");
  for (const char* t : {"index", "post", "page", "tag", "tags"}) {
    write(in / "templates" / (std::string(t) + ".html"), std::string(t) + ":{{ site.title }}\n\n");
  }
  write(in / "static/css/site.css", "body{}\n");
  write(in / "static/.hidden/dot", std::string("a\0b\xFF", 4));
  write(in / "static/empty.bin", "");

  generate_site(in, out);

  EXPECT_EQ(slurp(out / "index.html"), "index:T\n");  // one trailing LF removed from the template source
  EXPECT_EQ(slurp(out / "posts/first/index.html"), "post:T\n");
  EXPECT_EQ(slurp(out / "about/index.html"), "page:T\n");
  EXPECT_EQ(slurp(out / "tags/c/index.html"), "tag:T\n");
  EXPECT_EQ(slurp(out / "tags/index.html"), "tags:T\n");
  EXPECT_EQ(slurp(out / "css/site.css"), "body{}\n");
  EXPECT_EQ(slurp(out / ".hidden/dot"), std::string("a\0b\xFF", 4));
  EXPECT_TRUE(fs::exists(out / "empty.bin"));
  EXPECT_EQ(fs::file_size(out / "empty.bin"), 0u);
  EXPECT_NE(slurp(out / "feed.xml").find("https://x.org/blog/posts/first/"), std::string::npos);
  EXPECT_FALSE(fs::exists(out / "page"));
}

TEST(GenerateSite, MissingConfigurationThrows) {
  TempDir tmp;
  EXPECT_THROW(generate_site(tmp.path / "nothing", tmp.path / "out"), SiteError);
}
