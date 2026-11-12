#include <gtest/gtest.h>

#include "fulltext/analyzer.hpp"

using namespace fulltext;

namespace {
std::vector<std::string> texts(std::string_view s) {
  std::vector<std::string> out;
  for (const Token& t : analyze(s)) out.push_back(t.text);
  return out;
}
using V = std::vector<std::string>;
}  // namespace

TEST(Tokenizer, SpecExamples) {
  EXPECT_EQ(texts("The cat sat."), (V{"the", "cat", "sat"}));
  EXPECT_EQ(texts("don't stop"), (V{"dont", "stop"}));
  EXPECT_EQ(texts("'quoted'"), (V{"quoted"}));
  EXPECT_EQ(texts("rock'n'roll"), (V{"rocknroll"}));
  EXPECT_EQ(texts("a''b"), (V{"a", "b"}));
  EXPECT_EQ(texts("well-known"), (V{"well", "known"}));
  EXPECT_EQ(texts("Version 1.2.3"), (V{"version", "1", "2", "3"}));
  EXPECT_EQ(texts("X1 XY2Z"), (V{"x1", "xy2z"}));
  EXPECT_EQ(texts("Don\xE2\x80\x99t"), (V{"dont"}));
}

TEST(Tokenizer, SpansAreByteRangesOfRawTokens) {
  const std::string text = "  Don't  go. ";
  const auto spans = tokenize(text);
  ASSERT_EQ(spans.size(), 2u);
  EXPECT_EQ(text.substr(spans[0].begin, spans[0].end - spans[0].begin), "Don't");
  EXPECT_EQ(text.substr(spans[1].begin, spans[1].end - spans[1].begin), "go");
}

TEST(Tokenizer, UnicodeRanges) {
  // Multiplication and division signs are separators; accented, Greek and
  // Cyrillic letters are token characters; CJK is a separator.
  EXPECT_EQ(texts("a\xC3\x97" "b"), (V{"a", "b"}));
  EXPECT_EQ(texts("a\xC3\xB7" "b"), (V{"a", "b"}));
  EXPECT_EQ(texts("Caf\xC3\xA9"), (V{"caf\xC3\xA9"}));
  EXPECT_EQ(texts("CAF\xC3\x89"), (V{"caf\xC3\x89"}));  // only ASCII is lowered
  EXPECT_EQ(texts("\xCE\xB1\xCE\xB2 \xD0\x96\xD0\xB6"), (V{"\xCE\xB1\xCE\xB2", "\xD0\x96\xD0\xB6"}));
  EXPECT_EQ(texts("\xE4\xB8\xAD" "a"), (V{"a"}));
}

TEST(Tokenizer, EmptyAndSeparatorOnly) {
  EXPECT_TRUE(tokenize("").empty());
  EXPECT_TRUE(tokenize(" ... '' -- ").empty());
}

TEST(Analyzer, StopWords) {
  EXPECT_TRUE(is_stop_word("the"));
  EXPECT_TRUE(is_stop_word("with"));
  EXPECT_FALSE(is_stop_word("cat"));
  EXPECT_FALSE(is_stop_word("thes"));
}

TEST(Analyzer, TermsAreStemmedOnlyWhenPureAsciiLetters) {
  EXPECT_EQ(term_for("running"), "run");
  EXPECT_EQ(term_for("running2"), "running2");
  EXPECT_EQ(term_for("caf\xC3\xA9s"), "caf\xC3\xA9s");
  const auto tokens = analyze("Running Dogs");
  ASSERT_EQ(tokens.size(), 2u);
  EXPECT_EQ(tokens[0].term, "run");
  EXPECT_EQ(tokens[1].term, "dog");
}
