#include "mime/address.hpp"

#include <optional>

#include "mime/rfc2047.hpp"
#include "mime/text.hpp"

namespace mime {
namespace {

enum class TokenKind { Atom, Quoted, Literal, Encoded, Special };

struct Token {
  TokenKind kind;
  std::string text;
  std::size_t begin;  // offset of the token's first character in the value
};

bool is_special(const Token& t, char c) {
  return t.kind == TokenKind::Special && t.text[0] == c;
}

bool is_special_char(char c) {
  switch (c) {
    case '<': case '>': case '@': case ',': case ':': case ';': case '.': return true;
    default: return false;
  }
}

bool ends_atom(char c) {
  if (is_blank(c) || is_special_char(c)) return true;
  switch (c) {
    case '(': case ')': case '[': case ']': case '"': case '\\': return true;
    default: return false;
  }
}

std::vector<Token> tokenize(std::string_view v) {
  std::vector<Token> toks;
  std::size_t i = 0;
  while (i < v.size()) {
    char c = v[i];
    if (is_blank(c)) {
      ++i;
    } else if (c == '(') {
      i = skip_comment(v, i);
    } else if (c == '"') {
      QuotedString q = scan_quoted(v, i);
      toks.push_back({TokenKind::Quoted, std::move(q.text), i});
      i = q.end;
    } else if (c == '[') {
      std::size_t start = i++;
      while (i < v.size()) {
        if (v[i] == '\\' && i + 1 < v.size()) {
          i += 2;
        } else if (v[i] == ']') {
          ++i;
          break;
        } else {
          ++i;
        }
      }
      toks.push_back({TokenKind::Literal, std::string(v.substr(start, i - start)), start});
    } else if (auto w = match_encoded_word(v, i)) {
      toks.push_back({TokenKind::Encoded, std::move(w->text), i});
      i = w->end;
    } else if (is_special_char(c)) {
      toks.push_back({TokenKind::Special, std::string(1, c), i});
      ++i;
    } else if (c == ')' || c == ']' || c == '\\') {
      toks.push_back({TokenKind::Atom, std::string(1, c), i});
      ++i;
    } else {
      std::size_t start = i;
      while (i < v.size() && !ends_atom(v[i])) ++i;
      toks.push_back({TokenKind::Atom, std::string(v.substr(start, i - start)), start});
    }
  }
  return toks;
}

using Span = std::vector<Token>;

// Reads ATOM ('.' ATOM)* (QUOTED allowed too when `quoted`), advancing `i`.
bool read_dotted(const Span& t, std::size_t& i, bool quoted, std::string& out) {
  bool first = true;
  while (true) {
    if (i >= t.size()) return false;
    if (!(t[i].kind == TokenKind::Atom || (quoted && t[i].kind == TokenKind::Quoted)))
      return false;
    if (!first) out += '.';
    out += t[i].text;
    first = false;
    ++i;
    if (i < t.size() && is_special(t[i], '.')) {
      ++i;
    } else {
      return true;
    }
  }
}

// Renders `local [@ domain]` if the tokens have that exact shape.
std::optional<std::string> render_addr_spec(const Span& t, std::size_t from, std::size_t to) {
  Span s(t.begin() + from, t.begin() + to);
  std::size_t i = 0;
  std::string out;
  if (!read_dotted(s, i, true, out)) return std::nullopt;
  if (i == s.size()) return out;
  if (!is_special(s[i], '@')) return std::nullopt;
  ++i;
  out += '@';
  if (i < s.size() && s[i].kind == TokenKind::Literal) {
    if (i + 1 != s.size()) return std::nullopt;
    return out + s[i].text;
  }
  if (!read_dotted(s, i, false, out) || i != s.size()) return std::nullopt;
  return out;
}

void parse_element(std::string_view value, Span toks, std::vector<Address>& out) {
  // Group syntax: drop everything up to a ':' that precedes any '<' or '@'.
  for (std::size_t i = 0; i < toks.size(); ++i) {
    if (is_special(toks[i], '<') || is_special(toks[i], '@')) break;
    if (is_special(toks[i], ':')) {
      toks.erase(toks.begin(), toks.begin() + static_cast<std::ptrdiff_t>(i) + 1);
      break;
    }
  }
  if (!toks.empty() && is_special(toks.back(), ';')) toks.pop_back();
  if (toks.empty()) return;

  std::size_t lt = toks.size();
  for (std::size_t i = 0; i < toks.size(); ++i)
    if (is_special(toks[i], '<')) { lt = i; break; }

  if (lt < toks.size()) {
    std::size_t gt = toks.size();
    for (std::size_t i = toks.size(); i-- > lt + 1;)
      if (is_special(toks[i], '>')) { gt = i; break; }
    if (gt < toks.size()) {
      if (auto spec = render_addr_spec(toks, lt + 1, gt)) {
        std::size_t begin = toks[0].begin;
        out.push_back({decode_display(value.substr(begin, toks[lt].begin - begin)), *spec});
        return;
      }
    }
  } else if (auto spec = render_addr_spec(toks, 0, toks.size())) {
    out.push_back({"", *spec});
    return;
  }
  std::string glued;
  for (const Token& t : toks) glued += t.text;
  out.push_back({"", std::move(glued)});
}

}  // namespace

std::vector<Address> parse_address_list(std::string_view value) {
  std::vector<Token> toks = tokenize(value);
  std::vector<Address> out;
  Span element;
  int depth = 0;
  for (Token& t : toks) {
    if (is_special(t, '<')) {
      ++depth;
    } else if (is_special(t, '>')) {
      if (depth > 0) --depth;
    } else if (is_special(t, ',') && depth == 0) {
      parse_element(value, std::move(element), out);
      element.clear();
      continue;
    }
    element.push_back(std::move(t));
  }
  parse_element(value, std::move(element), out);
  return out;
}

}  // namespace mime
