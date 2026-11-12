#include <gtest/gtest.h>

#include "jsonschema/uri.hpp"

using namespace jsonschema;

// RFC 3986 section 5.4 examples.
TEST(Uri, ResolvesNormalExamples) {
  const std::string base = "http://a/b/c/d;p?q";
  struct Case { const char* ref; const char* want; };
  for (Case c : {Case{"g:h", "g:h"}, Case{"g", "http://a/b/c/g"}, Case{"./g", "http://a/b/c/g"},
                 Case{"g/", "http://a/b/c/g/"}, Case{"/g", "http://a/g"}, Case{"//g", "http://g"},
                 Case{"?y", "http://a/b/c/d;p?y"}, Case{"g?y", "http://a/b/c/g?y"}, Case{"#s", "http://a/b/c/d;p?q#s"},
                 Case{"g#s", "http://a/b/c/g#s"}, Case{"", "http://a/b/c/d;p?q"}, Case{".", "http://a/b/c/"},
                 Case{"..", "http://a/b/"}, Case{"../g", "http://a/b/g"}, Case{"../..", "http://a/"},
                 Case{"../../g", "http://a/g"}, Case{"../../../g", "http://a/g"}, Case{"/./g", "http://a/g"},
                 Case{"g/./h", "http://a/b/c/g/h"}, Case{"g/../h", "http://a/b/c/h"}, Case{"g.", "http://a/b/c/g."},
                 Case{".g", "http://a/b/c/.g"}}) {
    EXPECT_EQ(uri::resolve(c.ref, base), c.want) << c.ref;
  }
}

TEST(Uri, ResolvesAgainstEmptyBase) {
  EXPECT_EQ(uri::resolve("#/$defs/a", ""), "#/$defs/a");
  EXPECT_EQ(uri::resolve("foo.json", ""), "foo.json");
  EXPECT_EQ(uri::resolve("http://x/y", ""), "http://x/y");
}

TEST(Uri, ResolvesAgainstUrn) {
  EXPECT_EQ(uri::resolve("#foo", "urn:uuid:1234"), "urn:uuid:1234#foo");
  EXPECT_EQ(uri::resolve("urn:other", "urn:uuid:1234"), "urn:other");
}

TEST(Uri, RemoveDotSegments) {
  EXPECT_EQ(uri::remove_dot_segments("/a/b/c/./../../g"), "/a/g");
  EXPECT_EQ(uri::remove_dot_segments("mid/content=5/../6"), "mid/6");
}

TEST(Uri, FragmentHelpers) {
  EXPECT_EQ(uri::strip_fragment("http://x/y#z"), "http://x/y");
  auto [doc, frag] = uri::split_fragment("http://x/y#");
  EXPECT_EQ(doc, "http://x/y");
  ASSERT_TRUE(frag.has_value());
  EXPECT_EQ(*frag, "");
  EXPECT_FALSE(uri::split_fragment("http://x/y").second.has_value());
  EXPECT_EQ(uri::percent_decode("%24defs%2Ffoo%25"), "$defs/foo%");
  EXPECT_EQ(uri::percent_decode("100%"), "100%");
}

TEST(Uri, JsonPointer) {
  auto t = uri::parse_json_pointer("/a~1b/m~0n/");
  ASSERT_TRUE(t.has_value());
  ASSERT_EQ(t->size(), 3u);
  EXPECT_EQ((*t)[0], "a/b");
  EXPECT_EQ((*t)[1], "m~n");
  EXPECT_EQ((*t)[2], "");
  EXPECT_TRUE(uri::parse_json_pointer("")->empty());
  EXPECT_FALSE(uri::parse_json_pointer("a").has_value());
}
