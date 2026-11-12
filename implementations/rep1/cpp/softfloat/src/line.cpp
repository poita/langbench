#include "softfloat/line.h"

#include "softfloat/softfloat.h"

namespace softfloat {

namespace {

bool parse_hex8(std::string_view s, Bits32& out) {
  if (s.size() != 8) return false;
  Bits32 v = 0;
  for (char c : s) {
    int d;
    if (c >= '0' && c <= '9') d = c - '0';
    else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
    else return false;
    v = (v << 4) | static_cast<Bits32>(d);
  }
  out = v;
  return true;
}

}  // namespace

std::string format_bits(Bits32 x) {
  static constexpr char kDigits[] = "0123456789abcdef";
  std::string s(8, '0');
  for (int i = 7; i >= 0; --i, x >>= 4) s[static_cast<std::size_t>(i)] = kDigits[x & 0xf];
  return s;
}

std::optional<Bits32> evaluate_line(std::string_view line) {
  // Split on single spaces into at most 3 tokens.
  std::string_view tok[4];
  int n = 0;
  while (true) {
    if (n == 3) return std::nullopt;
    const std::size_t sp = line.find(' ');
    tok[n++] = line.substr(0, sp);
    if (sp == std::string_view::npos) break;
    line.remove_prefix(sp + 1);
  }
  const std::string_view op = tok[0];
  Bits32 a = 0, b = 0;
  if (op == "sqrt") {
    if (n != 2 || !parse_hex8(tok[1], a)) return std::nullopt;
    return sqrt(a);
  }
  if (n != 3 || !parse_hex8(tok[1], a) || !parse_hex8(tok[2], b)) return std::nullopt;
  if (op == "add") return add(a, b);
  if (op == "sub") return sub(a, b);
  if (op == "mul") return mul(a, b);
  if (op == "div") return div(a, b);
  return std::nullopt;
}

std::optional<std::string> evaluate_all(std::string_view input, std::size_t* bad_line) {
  std::string out;
  out.reserve(input.size() / 2 + 16);
  std::size_t lineno = 0;
  while (!input.empty()) {
    const std::size_t nl = input.find('\n');
    std::string_view line = input.substr(0, nl);
    input.remove_prefix(nl == std::string_view::npos ? input.size() : nl + 1);
    ++lineno;
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    const auto r = evaluate_line(line);
    if (!r) {
      if (bad_line) *bad_line = lineno;
      return std::nullopt;
    }
    out += format_bits(*r);
    out += '\n';
  }
  return out;
}

}  // namespace softfloat
