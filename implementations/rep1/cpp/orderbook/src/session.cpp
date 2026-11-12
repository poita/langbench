#include "orderbook/session.hpp"

#include <charconv>

#include "orderbook/command.hpp"
#include "orderbook/order_book.hpp"
#include "orderbook/text_writer.hpp"

namespace orderbook {

SessionResult run_session(std::string_view input, std::ostream& out) {
  SessionResult res;
  auto fail = [&](std::size_t line, const char* what) {
    res.ok = false;
    res.error = "line " + std::to_string(line) + ": " + what;
    return res;
  };

  std::size_t pos = 0;
  auto next_line = [&](std::string_view& line) {
    if (pos >= input.size()) return false;
    const std::size_t nl = input.find('\n', pos);
    const std::size_t end = nl == std::string_view::npos ? input.size() : nl;
    line = input.substr(pos, end - pos);
    pos = nl == std::string_view::npos ? input.size() : nl + 1;
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    return true;
  };

  std::string_view line;
  if (!next_line(line)) return res;  // empty input: nothing to do
  std::size_t n = 0;
  {
    auto [p, ec] = std::from_chars(line.data(), line.data() + line.size(), n);
    if (ec != std::errc{} || p != line.data() + line.size()) return fail(1, "bad command count");
  }

  OrderBook book;
  TextEventWriter writer(out);
  for (std::size_t i = 0; i < n && next_line(line); ++i) {
    const auto cmd = parse_command(line);
    if (!cmd) {
      writer.flush();
      return fail(i + 2, "malformed command");
    }
    book.execute(*cmd, writer);
    ++res.commands;
  }
  writer.flush();
  return res;
}

}  // namespace orderbook
