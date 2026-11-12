#include "fulltext/analyzer.hpp"

#include <unordered_set>

#include "fulltext/stemmer.hpp"
#include "fulltext/utf8.hpp"

namespace fulltext {

namespace {

bool is_token_char(char32_t c) noexcept {
  return (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
         (c >= 0xC0 && c <= 0xD6) || (c >= 0xD8 && c <= 0xF6) || (c >= 0xF8 && c <= 0x24F) ||
         (c >= 0x370 && c <= 0x3FF) || (c >= 0x400 && c <= 0x4FF);
}

bool is_apostrophe(char32_t c) noexcept { return c == 0x27 || c == 0x2019; }

}  // namespace

std::vector<Span> tokenize(std::string_view text) {
  std::vector<Span> spans;
  const std::size_t n = text.size();
  std::size_t i = 0;
  while (i < n) {
    const auto d = utf8::decode(text, i);
    if (!is_token_char(d.cp)) {
      i += d.len;
      continue;
    }
    const std::size_t start = i;
    i += d.len;
    while (i < n) {
      const auto c = utf8::decode(text, i);
      if (is_token_char(c.cp)) {
        i += c.len;
      } else if (is_apostrophe(c.cp) && i + c.len < n &&
                 is_token_char(utf8::decode(text, i + c.len).cp)) {
        i += c.len;  // the following token character is taken on the next turn
      } else {
        break;
      }
    }
    spans.push_back({start, i});
  }
  return spans;
}

std::string fold(std::string_view raw) {
  std::string out;
  out.reserve(raw.size());
  std::size_t i = 0;
  while (i < raw.size()) {
    const auto d = utf8::decode(raw, i);
    if (!is_apostrophe(d.cp)) {
      if (d.len == 1 && raw[i] >= 'A' && raw[i] <= 'Z') {
        out.push_back(static_cast<char>(raw[i] + 32));
      } else {
        out.append(raw.substr(i, d.len));
      }
    }
    i += d.len;
  }
  return out;
}

bool is_stop_word(std::string_view folded) {
  static const std::unordered_set<std::string_view> stop = {
      "a",    "an",   "and",  "are",   "as",   "at",    "be",    "but",   "by",
      "for",  "if",   "in",   "into",  "is",   "it",    "no",    "not",   "of",
      "on",   "or",   "such", "that",  "the",  "their", "then",  "there", "these",
      "they", "this", "to",   "was",   "will", "with"};
  return stop.count(folded) != 0;
}

std::string term_for(std::string_view folded) {
  for (char c : folded) {
    if (c < 'a' || c > 'z') return std::string(folded);
  }
  return porter_stem(folded);
}

std::vector<Token> analyze(std::string_view text) {
  std::vector<Token> tokens;
  for (const Span& s : tokenize(text)) {
    Token t;
    t.span = s;
    t.text = fold(text.substr(s.begin, s.end - s.begin));
    t.term = term_for(t.text);
    tokens.push_back(std::move(t));
  }
  return tokens;
}

}  // namespace fulltext
