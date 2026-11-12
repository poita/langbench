#include <gtest/gtest.h>

#include "gitrepo/quote.hpp"

using gitrepo::quote_path;

TEST(QuotePath, PlainNamesAreUnchanged) {
  EXPECT_EQ(quote_path("src/main.cpp"), "src/main.cpp");
  EXPECT_EQ(quote_path("with space"), "with space");
  EXPECT_EQ(quote_path(""), "");
}

TEST(QuotePath, NonAsciiBecomesOctal) {
  EXPECT_EQ(quote_path("caf\xc3\xa9.txt"), "\"caf\\303\\251.txt\"");
}

TEST(QuotePath, QuoteAndBackslash) {
  EXPECT_EQ(quote_path("quote\"and\\slash.txt"), "\"quote\\\"and\\\\slash.txt\"");
}

TEST(QuotePath, ControlCharacters) {
  EXPECT_EQ(quote_path("a\tb"), "\"a\\tb\"");
  EXPECT_EQ(quote_path("a\nb\r\a\b\v\f"), "\"a\\nb\\r\\a\\b\\v\\f\"");
  EXPECT_EQ(quote_path(std::string("x\x01y")), "\"x\\001y\"");
  EXPECT_EQ(quote_path("x\x7f"), "\"x\\177\"");
}
