#include "orderbook/command.hpp"

#include <array>
#include <charconv>

namespace orderbook {
namespace {

/// Splits a line on single spaces into at most `N` tokens.
struct Tokens {
  std::array<std::string_view, 6> t{};
  std::size_t n = 0;
  bool ok = true;
};

Tokens split(std::string_view line) noexcept {
  Tokens r;
  std::size_t pos = 0;
  while (true) {
    const std::size_t sp = line.find(' ', pos);
    const std::string_view tok =
        line.substr(pos, sp == std::string_view::npos ? std::string_view::npos : sp - pos);
    if (tok.empty() || r.n == r.t.size()) {
      r.ok = false;
      return r;
    }
    r.t[r.n++] = tok;
    if (sp == std::string_view::npos) return r;
    pos = sp + 1;
  }
}

bool parse_positive(std::string_view s, std::int64_t& out) noexcept {
  if (s.empty() || s.size() > 18 || s[0] == '0') return false;
  std::int64_t v = 0;
  auto [p, ec] = std::from_chars(s.data(), s.data() + s.size(), v);
  if (ec != std::errc{} || p != s.data() + s.size() || v < 1) return false;
  out = v;
  return true;
}

bool parse_side(std::string_view s, Side& out) noexcept {
  if (s == "BUY") out = Side::Buy;
  else if (s == "SELL") out = Side::Sell;
  else return false;
  return true;
}

bool valid_id(std::string_view s) noexcept { return !s.empty() && s.size() <= kMaxIdLength; }

}  // namespace

std::optional<Command> parse_command(std::string_view line) noexcept {
  if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
  const Tokens tk = split(line);
  if (!tk.ok) return std::nullopt;
  const auto& t = tk.t;
  Command c;
  const std::string_view kw = t[0];

  if (kw == "LIMIT") {
    if (tk.n != 5 && tk.n != 6) return std::nullopt;
    c.type = CommandType::Limit;
    c.id = t[1];
    if (!valid_id(c.id) || !parse_side(t[2], c.side) || !parse_positive(t[3], c.price) ||
        !parse_positive(t[4], c.qty))
      return std::nullopt;
    if (tk.n == 6) {
      if (t[5] == "IOC") c.tif = TimeInForce::ImmediateOrCancel;
      else if (t[5] == "FOK") c.tif = TimeInForce::FillOrKill;
      else return std::nullopt;
    }
  } else if (kw == "MARKET") {
    if (tk.n != 4) return std::nullopt;
    c.type = CommandType::Market;
    c.id = t[1];
    if (!valid_id(c.id) || !parse_side(t[2], c.side) || !parse_positive(t[3], c.qty))
      return std::nullopt;
  } else if (kw == "CANCEL") {
    if (tk.n != 2) return std::nullopt;
    c.type = CommandType::Cancel;
    c.id = t[1];
    if (!valid_id(c.id)) return std::nullopt;
  } else if (kw == "REPLACE") {
    if (tk.n != 4) return std::nullopt;
    c.type = CommandType::Replace;
    c.id = t[1];
    if (!valid_id(c.id) || !parse_positive(t[2], c.price) || !parse_positive(t[3], c.qty))
      return std::nullopt;
  } else if (kw == "BOOK") {
    if (tk.n != 1) return std::nullopt;
    c.type = CommandType::Book;
  } else {
    return std::nullopt;
  }
  return c;
}

}  // namespace orderbook
