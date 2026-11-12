#include <gtest/gtest.h>

#include <string>
#include <string_view>

#include "jsonschema/regex.hpp"

using jsonschema::Regex;
using jsonschema::RegexError;

namespace {
bool M(std::string_view pattern, std::string_view subject) { return Regex::compile(pattern).search(subject); }
}  // namespace

TEST(Regex, SearchIsUnanchored) {
  EXPECT_TRUE(M("bar", "foobarbaz"));
  EXPECT_FALSE(M("^bar", "foobarbaz"));
  EXPECT_TRUE(M("^foo", "foobarbaz"));
  EXPECT_TRUE(M("baz$", "foobarbaz"));
  EXPECT_FALSE(M("^a$", "a\n"));
  EXPECT_TRUE(M("", ""));
}

TEST(Regex, AlternationAndGroups) {
  EXPECT_TRUE(M("^(?:a|bc)d$", "bcd"));
  EXPECT_TRUE(M("^(a|b)*c$", "ababc"));
  EXPECT_FALSE(M("^(a|b)*c$", "abxc"));
  EXPECT_TRUE(M("^(a|)b$", "b"));
}

TEST(Regex, Quantifiers) {
  EXPECT_TRUE(M("^a{3}$", "aaa"));
  EXPECT_FALSE(M("^a{3}$", "aa"));
  EXPECT_TRUE(M("^a{2,}$", "aaaaa"));
  EXPECT_TRUE(M("^a{2,3}$", "aaa"));
  EXPECT_FALSE(M("^a{2,3}$", "aaaa"));
  EXPECT_TRUE(M("^a+?b*?$", "aaa"));
  EXPECT_TRUE(M("^a{,2}$", "a{,2}"));   // not a quantifier: literal
  EXPECT_TRUE(M("a{", "a{"));
  EXPECT_TRUE(M("^(a*)*$", "aaaa"));
  EXPECT_TRUE(M("^(a?){3}$", "aa"));
}

TEST(Regex, DotAndLineTerminators) {
  EXPECT_TRUE(M("^.$", "x"));
  EXPECT_FALSE(M("^.$", "\n"));
  EXPECT_FALSE(M("^.$", "\r"));
  EXPECT_FALSE(M("^.$", "\xE2\x80\xA8"));  // U+2028
  EXPECT_TRUE(M("^.$", "\xF0\x9F\x92\xA9"));  // one astral code point
}

TEST(Regex, Classes) {
  EXPECT_TRUE(M("^[a-c]+$", "abcabc"));
  EXPECT_FALSE(M("^[a-c]+$", "abd"));
  EXPECT_TRUE(M("^[^a-c]$", "d"));
  EXPECT_TRUE(M("^[a-]$", "-"));
  EXPECT_TRUE(M("^[-a]$", "-"));
  EXPECT_TRUE(M("^[\\-a]$", "-"));
  EXPECT_TRUE(M("^[\\d_]+$", "12_3"));
  EXPECT_TRUE(M("^[\\D]$", "x"));
  EXPECT_FALSE(M("^[\\D]$", "5"));
  EXPECT_TRUE(M("^[\\b]$", "\b"));
  EXPECT_TRUE(M("^[^]$", "\n"));
  EXPECT_FALSE(M("^[]$", "a"));
  EXPECT_TRUE(M("^[a-\\d]+$", "a-5"));
  EXPECT_TRUE(M("^[\\u0041-\\u005A]$", "Q"));
}

TEST(Regex, ClassEscapes) {
  EXPECT_TRUE(M("^\\d+$", "0123456789"));
  EXPECT_FALSE(M("\\d", "abc"));
  EXPECT_TRUE(M("^\\w+$", "aZ_09"));
  EXPECT_FALSE(M("^\\w+$", "\xC3\xA9"));
  EXPECT_TRUE(M("^\\W$", "\xC3\xA9"));
  EXPECT_TRUE(M("^\\s+$", " \t\n\r\f\v\xC2\xA0\xE3\x80\x80\xEF\xBB\xBF"));
  EXPECT_FALSE(M("\\s", "abc"));
  EXPECT_TRUE(M("^\\S+$", "abc"));
}

TEST(Regex, WordBoundaries) {
  EXPECT_TRUE(M("\\bcat\\b", "a cat sat"));
  EXPECT_FALSE(M("\\bcat\\b", "concatenate"));
  EXPECT_TRUE(M("\\bcat\\b", "\xC3\xA9" "cat "));  // é is not a word character
  EXPECT_TRUE(M("\\Bat", "cat"));
  EXPECT_FALSE(M("\\Bat", "at"));
}

TEST(Regex, CharacterEscapes) {
  EXPECT_TRUE(M("^\\n\\r\\t\\f\\v\\0$", "\n\r\t\f\v" + std::string(1, '\0')));
  EXPECT_TRUE(M("^\\x41\\u0042$", "AB"));
  EXPECT_TRUE(M("^\\ud83d\\udca9$", "\xF0\x9F\x92\xA9"));
  EXPECT_TRUE(M("^\\cJ$", "\n"));
  EXPECT_TRUE(M("^\\.\\*\\[\\\\\\/$", ".*[\\/"));
  EXPECT_FALSE(M("^\\.$", "x"));
}

TEST(Regex, UnicodeSubjects) {
  EXPECT_TRUE(M("^\xC3\xA9{2}$", "\xC3\xA9\xC3\xA9"));
  EXPECT_TRUE(M("^[\xC3\xA0-\xC3\xBF]$", "\xC3\xA9"));
}

TEST(Regex, NoExponentialBlowup) {
  // Classic catastrophic pattern for backtrackers.
  std::string subject(5000, 'a');
  subject += "b";
  EXPECT_FALSE(M("^(a+)+$", subject));
  EXPECT_FALSE(M("^(a|aa)+$", subject));
  EXPECT_FALSE(M("(x+x+)+y", std::string(5000, 'x')));
}

TEST(Regex, RejectsMalformedPatterns) {
  for (const char* p : {"(", ")", "[a", "*a", "a**", "(?=a)", "[b-a]", "a{3,2}", "\\"}) {
    EXPECT_THROW(Regex::compile(p), RegexError) << p;
  }
}
