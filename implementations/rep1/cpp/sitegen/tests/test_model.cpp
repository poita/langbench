#include <gtest/gtest.h>

#include "sitegen/model.hpp"

using namespace sitegen;

namespace {

toml::Document config(int per_page, const std::string& base = "https://example.com") {
  return toml::parse("title = \"T\"\nbase_url = \"" + base + "\"\nauthor = \"A\"\nposts_per_page = " +
                     std::to_string(per_page) + "\nextra = [\"x\", \"y\"]\nflag = true\n");
}

Post post(const std::string& slug, const std::string& date, std::vector<std::string> tags = {},
          const std::string& body = "body\n", bool draft = false) {
  Post p;
  p.title = "Post " + slug;
  p.slug = slug;
  p.date = date;
  p.tags = std::move(tags);
  p.body = body;
  p.draft = draft;
  return p;
}

const Value& member(const Value& dict, const char* key) {
  static const Value kUndefined;
  const Value* v = dict.as_dict().find(key);
  return v != nullptr ? *v : kUndefined;
}

}  // namespace

TEST(Slugify, FollowsTheFourSteps) {
  EXPECT_EQ(slugify_tag("Web Development"), "web-development");
  EXPECT_EQ(slugify_tag("C++"), "c");
  EXPECT_EQ(slugify_tag("Rust 2024"), "rust-2024");
  EXPECT_EQ(slugify_tag("--a  --  b--"), "a-b");
  EXPECT_EQ(slugify_tag("caf\xC3\xA9 au lait"), "caf-au-lait");
  EXPECT_EQ(slugify_tag("???"), "");
}

TEST(LongDate, FormatsMonthNamesWithoutLeadingZero) {
  EXPECT_EQ(format_long_date("2024-03-05"), "March 5, 2024");
  EXPECT_EQ(format_long_date("1999-12-25"), "December 25, 1999");
  EXPECT_EQ(format_long_date("2020-01-01"), "January 1, 2020");
}

TEST(Excerpt, TakesTheFirstBlockTextually) {
  EXPECT_EQ(excerpt_source("Hello\nworld\n\nsecond"), "Hello\nworld");
  EXPECT_EQ(excerpt_source("\n \t \n# Title\nmore\n\nx"), "# Title\nmore");
  EXPECT_EQ(excerpt_source("only"), "only");
  EXPECT_EQ(excerpt_source("  \n\t\n"), "");
  EXPECT_EQ(excerpt_source(""), "");
  EXPECT_EQ(excerpt_source("```\ncode\n\nmore\n```"), "```\ncode");
}

TEST(Model, PostsAreOrderedByDateDescendingThenSlug) {
  SiteSource src;
  src.config = config(10);
  src.posts = {post("b", "2024-01-01"), post("a", "2024-01-01"), post("z", "2025-01-01"),
               post("old", "2020-05-05"), post("hidden", "2030-01-01", {}, "x", true)};
  const SiteModel m = SiteModel::build(src);
  ASSERT_EQ(m.posts().size(), 4u);
  EXPECT_EQ(m.posts()[0].slug, "z");
  EXPECT_EQ(m.posts()[1].slug, "a");
  EXPECT_EQ(m.posts()[2].slug, "b");
  EXPECT_EQ(m.posts()[3].slug, "old");
}

TEST(Model, PostObjectHasTheDocumentedMembersInOrder) {
  SiteSource src;
  src.config = config(10);
  src.posts = {post("one", "2024-03-05", {"A", "B"}, "Hi *there*\n\nmore\n"), post("two", "2024-03-06")};
  const SiteModel m = SiteModel::build(src);
  const Value& v = m.posts()[1].value;
  std::vector<std::string> keys;
  for (const auto& e : v.as_dict().entries()) keys.push_back(e.first);
  EXPECT_EQ(keys, (std::vector<std::string>{"title", "slug", "url", "permalink", "date", "date_long", "tags", "content",
                                           "excerpt", "older", "newer"}));
  EXPECT_EQ(member(v, "url").as_string(), "/posts/one/");
  EXPECT_EQ(member(v, "permalink").as_string(), "https://example.com/posts/one/");
  EXPECT_EQ(member(v, "date_long").as_string(), "March 5, 2024");
  EXPECT_EQ(member(v, "content").as_string(), "<p>Hi <em>there</em></p>\n<p>more</p>\n");
  EXPECT_EQ(member(v, "excerpt").as_string(), "<p>Hi <em>there</em></p>\n");
  EXPECT_TRUE(member(v, "older").is_none());
  EXPECT_EQ(member(member(v, "newer"), "slug").as_string(), "two");
  ASSERT_EQ(member(v, "tags").as_list().size(), 2u);
  EXPECT_EQ(member(member(v, "tags").as_list()[1], "name").as_string(), "B");
}

TEST(Model, OlderAndNewerAreSiteWide) {
  SiteSource src;
  src.config = config(1);
  src.posts = {post("a", "2024-03-01", {"t"}), post("b", "2024-02-01"), post("c", "2024-01-01", {"t"})};
  const SiteModel m = SiteModel::build(src);
  ASSERT_EQ(m.tags().size(), 1u);
  const List& tagged = member(m.tags()[0].value, "posts").as_list();
  ASSERT_EQ(tagged.size(), 2u);
  // "a" and "c" share a tag but are not neighbours: b sits between them.
  EXPECT_EQ(member(member(tagged[0], "older"), "slug").as_string(), "b");
  EXPECT_EQ(member(member(tagged[1], "newer"), "slug").as_string(), "b");
}

TEST(Model, TagsExistOnlyForPublishedPostsAndAreOrderedBySlug) {
  SiteSource src;
  src.config = config(10);
  src.posts = {post("a", "2024-01-01", {"Zeta", "alpha", "Zeta"}), post("b", "2024-01-02", {"Web Development", "alpha"}),
               post("c", "2024-01-03", {"draft only"}, "x", true)};
  const SiteModel m = SiteModel::build(src);
  ASSERT_EQ(m.tags().size(), 3u);
  EXPECT_EQ(m.tags()[0].slug, "alpha");
  EXPECT_EQ(m.tags()[1].slug, "web-development");
  EXPECT_EQ(m.tags()[2].slug, "zeta");
  EXPECT_EQ(m.tags()[0].post_indices.size(), 2u);
  EXPECT_EQ(member(m.tag_links().as_list()[0], "post_count").as_int(), 2);
  // A repeated tag in one post counts once and keeps its first position.
  EXPECT_EQ(m.posts()[1].tag_indices.size(), 2u);
  // Tag posts are in canonical order (newest first).
  EXPECT_EQ(m.posts()[m.tags()[0].post_indices[0]].slug, "b");
}

TEST(Model, PagesAreOrderedBySlugAndDraftsDropped) {
  SiteSource src;
  src.config = config(10);
  Page a, b, c;
  a.title = "A";
  a.slug = "zebra";
  b.title = "B";
  b.slug = "about";
  b.body = "# About\n";
  c.title = "C";
  c.slug = "hidden";
  c.draft = true;
  src.pages = {a, b, c};
  const SiteModel m = SiteModel::build(src);
  ASSERT_EQ(m.pages().size(), 2u);
  EXPECT_EQ(m.pages()[0].slug, "about");
  EXPECT_EQ(m.pages()[0].content_html, "<h1>About</h1>\n");
  EXPECT_EQ(member(m.pages()[0].link, "url").as_string(), "/about/");
  EXPECT_EQ(m.page_links().as_list().size(), 2u);
}

TEST(Model, PaginationMath) {
  SiteSource src;
  src.config = config(2);
  for (int i = 0; i < 5; ++i) src.posts.push_back(post("p" + std::to_string(i), "2024-01-0" + std::to_string(i + 1)));
  const SiteModel m = SiteModel::build(src);
  EXPECT_EQ(m.total_pages(), 3u);
  EXPECT_EQ(m.index_posts(1).as_list().size(), 2u);
  EXPECT_EQ(m.index_posts(3).as_list().size(), 1u);
  EXPECT_EQ(member(m.index_posts(3).as_list()[0], "slug").as_string(), "p0");

  const Value p2 = m.pagination(2);
  EXPECT_EQ(member(p2, "number").as_int(), 2);
  EXPECT_EQ(member(p2, "total_pages").as_int(), 3);
  EXPECT_EQ(member(p2, "total_posts").as_int(), 5);
  EXPECT_TRUE(member(p2, "has_prev").as_bool());
  EXPECT_TRUE(member(p2, "has_next").as_bool());
  EXPECT_EQ(member(p2, "prev_url").as_string(), "/");
  EXPECT_EQ(member(p2, "next_url").as_string(), "/page/3/");
  const List& links = member(p2, "links").as_list();
  ASSERT_EQ(links.size(), 3u);
  EXPECT_EQ(member(links[1], "url").as_string(), "/page/2/");
  EXPECT_FALSE(member(links[0], "current").as_bool());
  EXPECT_TRUE(member(links[1], "current").as_bool());

  const Value p1 = m.pagination(1);
  EXPECT_TRUE(member(p1, "prev_url").is_none());
  EXPECT_FALSE(member(p1, "has_prev").as_bool());
  EXPECT_TRUE(member(m.pagination(3), "next_url").is_none());
}

TEST(Model, NoPostsStillHasOneIndexPage) {
  SiteSource src;
  src.config = config(3);
  const SiteModel m = SiteModel::build(src);
  EXPECT_EQ(m.total_pages(), 1u);
  EXPECT_TRUE(m.index_posts(1).as_list().empty());
  EXPECT_EQ(member(m.pagination(1), "total_posts").as_int(), 0);
}

TEST(Model, SiteValueKeepsFileOrderAndTypes) {
  SiteSource src;
  src.config = config(3);
  const SiteModel m = SiteModel::build(src);
  const auto& e = m.site_value().as_dict().entries();
  ASSERT_EQ(e.size(), 6u);
  EXPECT_EQ(e[0].first, "title");
  EXPECT_EQ(e[4].first, "extra");
  EXPECT_TRUE(e[4].second.is_list());
  EXPECT_TRUE(e[5].second.is_bool());
}

TEST(Model, InvalidConfigurationThrows) {
  SiteSource src;
  src.config = toml::parse("title = \"T\"\n");
  EXPECT_THROW(SiteModel::build(src), SiteError);
  src.config = toml::parse("title = \"T\"\nbase_url = \"u\"\nauthor = \"a\"\nposts_per_page = 0\n");
  EXPECT_THROW(SiteModel::build(src), SiteError);
}

TEST(Source, ParsePostAppliesDefaults) {
  const Post p = parse_post("my-file", "+++\ntitle = \"T\"\ndate = \"2024-01-02\"\n+++\nHello\n");
  EXPECT_EQ(p.slug, "my-file");
  EXPECT_TRUE(p.tags.empty());
  EXPECT_FALSE(p.draft);
  EXPECT_EQ(p.body, "Hello\n");
  const Post q = parse_post("f", "+++\ntitle = \"T\"\ndate = \"2024-01-02\"\nslug = \"s\"\ntags = [\"a\"]\ndraft = true\n+++\n");
  EXPECT_EQ(q.slug, "s");
  EXPECT_EQ(q.tags, std::vector<std::string>{"a"});
  EXPECT_TRUE(q.draft);
  EXPECT_THROW(parse_post("f", "+++\ntitle = \"T\"\n+++\n"), SiteError);
}

TEST(Source, ParsePageAppliesDefaults) {
  const Page p = parse_page("about", "+++\ntitle = \"About\"\n+++\n# Hi");
  EXPECT_EQ(p.slug, "about");
  EXPECT_EQ(p.body, "# Hi");
}
