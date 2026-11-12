#include "mime/params.hpp"

#include <algorithm>
#include <cstdint>
#include <utility>
#include <vector>

#include "mime/charset.hpp"
#include "mime/rfc2047.hpp"
#include "mime/text.hpp"

namespace mime {
namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

std::string percent_decode(std::string_view s) {
  std::string out;
  for (std::size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '%' && i + 2 < s.size() && hex_value(s[i + 1]) >= 0 &&
        hex_value(s[i + 2]) >= 0) {
      out += static_cast<char>(hex_value(s[i + 1]) * 16 + hex_value(s[i + 2]));
      i += 2;
    } else {
      out += s[i];
    }
  }
  return out;
}

// `charset'language'text` -> (charset, text); fewer than two quotes means the
// whole value is text and the charset is us-ascii. An empty charset also
// means us-ascii.
void split_extended(std::string_view v, std::string& charset, std::string_view& text) {
  charset = "us-ascii";
  text = v;
  std::size_t a = v.find('\'');
  if (a == std::string_view::npos) return;
  std::size_t b = v.find('\'', a + 1);
  if (b == std::string_view::npos) return;
  if (a > 0) charset = std::string(v.substr(0, a));
  text = v.substr(b + 1);
}

struct RawParam {
  std::string name;
  std::string value;
};

// Splits at top-level semicolons and extracts name=value pairs (first wins).
std::pair<std::string, std::vector<RawParam>> split_segments(std::string_view raw) {
  std::vector<std::string_view> segments;
  std::size_t start = 0, i = 0;
  while (i < raw.size()) {
    if (raw[i] == '"') {
      i = scan_quoted(raw, i).end;
    } else if (raw[i] == ';') {
      segments.push_back(raw.substr(start, i - start));
      start = ++i;
    } else {
      ++i;
    }
  }
  segments.push_back(raw.substr(start));

  std::vector<RawParam> params;
  for (std::size_t k = 1; k < segments.size(); ++k) {
    std::string_view seg = segments[k];
    std::size_t eq = seg.find('=');
    if (eq == std::string_view::npos) continue;
    std::string name = ascii_lower(strip_blanks(seg.substr(0, eq)));
    std::string_view value = strip_blanks(seg.substr(eq + 1));
    std::string text = (!value.empty() && value[0] == '"') ? scan_quoted(value, 0).text
                                                           : std::string(value);
    bool seen = false;
    for (const RawParam& p : params)
      if (p.name == name) { seen = true; break; }
    if (!seen) params.push_back({std::move(name), std::move(text)});
  }
  return {std::string(segments[0]), std::move(params)};
}

struct Segment {
  std::uint64_t number;
  bool extended;
  std::string value;
};

struct Group {
  std::vector<Segment> segments;
  std::optional<std::string> extended;
  std::optional<std::string> plain;
};

constexpr std::uint64_t kSegmentCap = 1000000000000000000ull;

bool all_digits(std::string_view s) {
  if (s.empty()) return false;
  for (char c : s)
    if (c < '0' || c > '9') return false;
  return true;
}

}  // namespace

std::optional<std::string> StructuredValue::param(const std::string& name) const {
  auto it = params.find(name);
  if (it == params.end()) return std::nullopt;
  return it->second;
}

StructuredValue parse_structured(std::string_view raw) {
  auto [first, raw_params] = split_segments(raw);
  StructuredValue result;
  result.value = ascii_lower(strip_blanks(first));

  std::map<std::string, Group> groups;
  for (RawParam& p : raw_params) {
    std::string_view name = p.name;
    bool star_end = !name.empty() && name.back() == '*';
    std::string_view m = star_end ? name.substr(0, name.size() - 1) : name;
    std::size_t star = m.rfind('*');
    if (star != std::string_view::npos && star > 0 && all_digits(m.substr(star + 1))) {
      std::string_view digits = m.substr(star + 1);
      std::uint64_t number = 0;
      for (char c : digits) {
        number = number * 10 + static_cast<std::uint64_t>(c - '0');
        if (number > kSegmentCap) number = kSegmentCap;
      }
      Group& g = groups[std::string(m.substr(0, star))];
      bool dup = false;
      for (const Segment& s : g.segments)
        if (s.number == number) { dup = true; break; }
      if (!dup) g.segments.push_back({number, star_end, std::move(p.value)});
    } else if (star_end && !m.empty()) {
      groups[std::string(m)].extended = std::move(p.value);
    } else {
      groups[p.name].plain = std::move(p.value);
    }
  }

  for (auto& [base, g] : groups) {
    if (!g.segments.empty()) {
      std::stable_sort(g.segments.begin(), g.segments.end(),
                       [](const Segment& a, const Segment& b) { return a.number < b.number; });
      std::string charset = "us-ascii";
      std::string bytes;
      for (const Segment& s : g.segments) {
        if (!s.extended) {
          bytes += s.value;
        } else if (s.number == 0) {
          std::string_view text;
          split_extended(s.value, charset, text);
          bytes += percent_decode(text);
        } else {
          bytes += percent_decode(s.value);
        }
      }
      result.params[base] = decode(bytes, charset);
    } else if (g.extended) {
      std::string charset;
      std::string_view text;
      split_extended(*g.extended, charset, text);
      result.params[base] = decode(percent_decode(text), charset);
    } else if (g.plain) {
      result.params[base] = decode_unstructured(*g.plain);
    }
  }
  return result;
}

}  // namespace mime
