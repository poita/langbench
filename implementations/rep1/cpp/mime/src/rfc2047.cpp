#include "mime/rfc2047.hpp"

#include <vector>

#include "mime/charset.hpp"
#include "mime/text.hpp"
#include "mime/transfer.hpp"

namespace mime {
namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

enum class ItemKind { Encoded, Space, Literal };
struct Item {
  ItemKind kind;
  std::string text;
};

std::string decode_q(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  for (std::size_t i = 0; i < text.size(); ++i) {
    char c = text[i];
    if (c == '_') {
      out += ' ';
    } else if (c == '=' && i + 2 < text.size() && hex_value(text[i + 1]) >= 0 &&
               hex_value(text[i + 2]) >= 0) {
      out += static_cast<char>(hex_value(text[i + 1]) * 16 + hex_value(text[i + 2]));
      i += 2;
    } else {
      out += c;
    }
  }
  return out;
}

// Concatenates items (dropping blanks between two encoded words) and strips.
std::string join_items(const std::vector<Item>& items) {
  std::string out;
  for (std::size_t i = 0; i < items.size(); ++i) {
    const Item& it = items[i];
    if (it.kind == ItemKind::Space && i > 0 && i + 1 < items.size() &&
        items[i - 1].kind == ItemKind::Encoded && items[i + 1].kind == ItemKind::Encoded)
      continue;
    out += it.text;
  }
  return std::string(strip_blanks(out));
}

// Shared scanner. In display mode comments and quoted strings are handled.
std::string decode_items(std::string_view v, bool display) {
  std::vector<Item> items;
  std::string run;
  ItemKind run_kind = ItemKind::Literal;
  bool have_run = false;
  auto flush = [&] {
    if (have_run) items.push_back({run_kind, std::move(run)});
    run.clear();
    have_run = false;
  };
  auto add_to_run = [&](ItemKind kind, char c) {
    if (have_run && run_kind != kind) flush();
    run_kind = kind;
    have_run = true;
    run += c;
  };
  std::size_t i = 0;
  while (i < v.size()) {
    char c = v[i];
    if (display && c == '(') {
      flush();
      items.push_back({ItemKind::Space, " "});
      i = skip_comment(v, i);
      continue;
    }
    if (display && c == '"') {
      flush();
      QuotedString q = scan_quoted(v, i);
      items.push_back({ItemKind::Literal, std::move(q.text)});
      i = q.end;
      continue;
    }
    if (c == '=') {
      if (auto w = match_encoded_word(v, i)) {
        flush();
        items.push_back({ItemKind::Encoded, std::move(w->text)});
        i = w->end;
        continue;
      }
    }
    add_to_run(is_blank(c) ? ItemKind::Space : ItemKind::Literal, c);
    ++i;
  }
  flush();
  return join_items(items);
}

}  // namespace

std::optional<EncodedWord> match_encoded_word(std::string_view v, std::size_t i) {
  if (i + 1 >= v.size() || v[i] != '=' || v[i + 1] != '?') return std::nullopt;
  std::size_t j = v.find('?', i + 2);
  if (j == std::string_view::npos || j == i + 2) return std::nullopt;
  std::string_view charset_field = v.substr(i + 2, j - (i + 2));
  for (char c : charset_field)
    if (is_blank(c)) return std::nullopt;
  if (j + 2 >= v.size()) return std::nullopt;
  char enc = v[j + 1];
  if (!(enc == 'Q' || enc == 'q' || enc == 'B' || enc == 'b') || v[j + 2] != '?')
    return std::nullopt;
  std::size_t m = v.find('?', j + 3);
  if (m == std::string_view::npos) return std::nullopt;
  std::string_view text = v.substr(j + 3, m - (j + 3));
  for (char c : text)
    if (is_blank(c)) return std::nullopt;
  if (m + 1 >= v.size() || v[m + 1] != '=') return std::nullopt;

  std::string_view cs = charset_field.substr(0, charset_field.find('*'));
  std::string charset = normalize_charset_name(cs);
  if (charset.empty()) charset = "us-ascii";
  std::string bytes = (enc == 'Q' || enc == 'q') ? decode_q(text) : decode_base64(text);
  return EncodedWord{m + 2, decode(bytes, charset)};
}

std::string decode_unstructured(std::string_view v) { return decode_items(v, false); }

std::string decode_display(std::string_view v) { return decode_items(v, true); }

}  // namespace mime
