#include "fulltext/stemmer.hpp"

#include <array>
#include <cstddef>

namespace fulltext {

namespace {

// All helpers work on a prefix `b[0, len)` of the word being stemmed.

bool is_consonant(const std::string& b, std::size_t i) {
  switch (b[i]) {
    case 'a': case 'e': case 'i': case 'o': case 'u':
      return false;
    case 'y':
      return i == 0 || !is_consonant(b, i - 1);
    default:
      return true;
  }
}

/// The measure m of the prefix: the number of VC sequences in [C](VC){m}[V].
int measure(const std::string& b, std::size_t len) {
  int m = 0;
  std::size_t i = 0;
  while (i < len && is_consonant(b, i)) ++i;  // leading consonants
  while (i < len) {
    while (i < len && !is_consonant(b, i)) ++i;  // vowels
    if (i >= len) break;
    ++m;
    while (i < len && is_consonant(b, i)) ++i;  // consonants
  }
  return m;
}

bool contains_vowel(const std::string& b, std::size_t len) {
  for (std::size_t i = 0; i < len; ++i) {
    if (!is_consonant(b, i)) return true;
  }
  return false;
}

/// *d: the prefix ends with a doubled consonant.
bool ends_double_consonant(const std::string& b, std::size_t len) {
  return len >= 2 && b[len - 1] == b[len - 2] && is_consonant(b, len - 1);
}

/// *o: the prefix ends consonant-vowel-consonant, the last not w, x or y.
bool ends_cvc(const std::string& b, std::size_t len) {
  if (len < 3) return false;
  if (!is_consonant(b, len - 1) || is_consonant(b, len - 2) || !is_consonant(b, len - 3)) {
    return false;
  }
  const char c = b[len - 1];
  return c != 'w' && c != 'x' && c != 'y';
}

bool ends_with(const std::string& b, std::string_view suffix) {
  return b.size() >= suffix.size() &&
         std::string_view(b).substr(b.size() - suffix.size()) == suffix;
}

struct Rule {
  std::string_view suffix;
  std::string_view replacement;
};

/// Applies a step in which the first rule whose suffix matches is selected;
/// it fires only when the measure of the remaining stem exceeds `min_measure`.
template <std::size_t N>
void apply_rules(std::string& b, const std::array<Rule, N>& rules, int min_measure) {
  for (const Rule& r : rules) {
    if (!ends_with(b, r.suffix)) continue;
    const std::size_t stem_len = b.size() - r.suffix.size();
    if (measure(b, stem_len) > min_measure) {
      b.resize(stem_len);
      b.append(r.replacement);
    }
    return;
  }
}

void step1a(std::string& b) {
  if (ends_with(b, "sses")) {
    b.resize(b.size() - 2);
  } else if (ends_with(b, "ies")) {
    b.resize(b.size() - 2);
  } else if (ends_with(b, "ss")) {
    // unchanged
  } else if (ends_with(b, "s")) {
    b.pop_back();
  }
}

void step1b(std::string& b) {
  bool removed = false;
  if (ends_with(b, "eed")) {
    if (measure(b, b.size() - 3) > 0) b.pop_back();
    return;
  }
  if (ends_with(b, "ed")) {
    if (contains_vowel(b, b.size() - 2)) {
      b.resize(b.size() - 2);
      removed = true;
    }
  } else if (ends_with(b, "ing")) {
    if (contains_vowel(b, b.size() - 3)) {
      b.resize(b.size() - 3);
      removed = true;
    }
  }
  if (!removed) return;

  if (ends_with(b, "at") || ends_with(b, "bl") || ends_with(b, "iz")) {
    b.push_back('e');
  } else if (ends_double_consonant(b, b.size())) {
    const char c = b.back();
    if (c != 'l' && c != 's' && c != 'z') b.pop_back();
  } else if (measure(b, b.size()) == 1 && ends_cvc(b, b.size())) {
    b.push_back('e');
  }
}

void step1c(std::string& b) {
  if (ends_with(b, "y") && contains_vowel(b, b.size() - 1)) b.back() = 'i';
}

void step2(std::string& b) {
  static constexpr std::array<Rule, 21> rules{{
      {"ational", "ate"}, {"tional", "tion"}, {"enci", "ence"},  {"anci", "ance"},
      {"izer", "ize"},    {"bli", "ble"},     {"alli", "al"},    {"entli", "ent"},
      {"eli", "e"},       {"ousli", "ous"},   {"ization", "ize"}, {"ation", "ate"},
      {"ator", "ate"},    {"alism", "al"},    {"iveness", "ive"}, {"fulness", "ful"},
      {"ousness", "ous"}, {"aliti", "al"},    {"iviti", "ive"},  {"biliti", "ble"},
      {"logi", "log"},
  }};
  apply_rules(b, rules, 0);
}

void step3(std::string& b) {
  static constexpr std::array<Rule, 7> rules{{
      {"icate", "ic"}, {"ative", ""}, {"alize", "al"}, {"iciti", "ic"},
      {"ical", "ic"},  {"ful", ""},   {"ness", ""},
  }};
  apply_rules(b, rules, 0);
}

void step4(std::string& b) {
  static constexpr std::array<std::string_view, 19> suffixes{
      "al",  "ance", "ence", "er",  "ic",  "able", "ible", "ant", "ement", "ment",
      "ent", "ion",  "ou",   "ism", "ate", "iti",  "ous",  "ive", "ize"};
  for (std::string_view s : suffixes) {
    if (!ends_with(b, s)) continue;
    const std::size_t stem_len = b.size() - s.size();
    if (measure(b, stem_len) > 1 &&
        (s != "ion" || (stem_len > 0 && (b[stem_len - 1] == 's' || b[stem_len - 1] == 't')))) {
      b.resize(stem_len);
    }
    return;
  }
}

void step5(std::string& b) {
  if (ends_with(b, "e")) {
    const std::size_t stem_len = b.size() - 1;
    const int m = measure(b, stem_len);
    if (m > 1 || (m == 1 && !ends_cvc(b, stem_len))) b.pop_back();
  }
  if (!b.empty() && b.back() == 'l' && ends_double_consonant(b, b.size()) && measure(b, b.size()) > 1) {
    b.pop_back();
  }
}

}  // namespace

std::string porter_stem(std::string_view word) {
  std::string b(word);
  if (b.size() <= 2) return b;
  step1a(b);
  step1b(b);
  step1c(b);
  step2(b);
  step3(b);
  step4(b);
  step5(b);
  return b;
}

}  // namespace fulltext
