#include <gtest/gtest.h>

#include <stdexcept>

#include "jinjalite/engine.hpp"

using namespace jinjalite;

TEST(Document, SplitsTemplates) {
  Document d = parse_document("{\"a\": 1}\n--\n=== main\nHello\n=== other.x/y-z\nBye\n\n");
  ASSERT_EQ(d.templates.size(), 2u);
  EXPECT_EQ(d.templates[0].first, "main");
  EXPECT_EQ(d.templates[0].second, "Hello");
  EXPECT_EQ(d.templates[1].first, "other.x/y-z");
  EXPECT_EQ(d.templates[1].second, "Bye\n");
  EXPECT_EQ(d.context.as_dict().find("a")->as_int(), 1);
}

TEST(Document, EmptyBodies) {
  Document d = parse_document("{}\n--\n=== a\n\n=== b\n=== c\n");
  ASSERT_EQ(d.templates.size(), 3u);
  EXPECT_EQ(d.templates[0].second, "");
  EXPECT_EQ(d.templates[1].second, "");
  EXPECT_EQ(d.templates[2].second, "");
}

TEST(Document, LastBodyWithoutTrailingNewline) {
  Document d = parse_document("{}\n--\n=== a\nx");
  EXPECT_EQ(d.templates[0].second, "x");
}

TEST(Document, MultiLineJsonContext) {
  Document d = parse_document("{\n  \"k\": [\n    1\n  ]\n}\n--\n=== m\nz");
  EXPECT_EQ(d.context.as_dict().find("k")->as_list().size(), 1u);
}

TEST(Document, MalformedInput) {
  EXPECT_THROW(parse_document("{}\n"), std::runtime_error);
  EXPECT_THROW(parse_document("{}\n--\n"), std::runtime_error);
  EXPECT_THROW(parse_document("[]\n--\n=== a\nx"), std::runtime_error);
}

TEST(Document, ErrorLine) {
  EXPECT_EQ(render_document_or_error_line("{}\n--\n=== main\nhi"), "hi\n");
  EXPECT_EQ(render_document_or_error_line("{}\n--\n=== main\n{% if %}"), "error: syntax\n");
  EXPECT_EQ(render_document_or_error_line("{}\n--\n=== main\n{{ x }}"), "error: undefined\n");
}
