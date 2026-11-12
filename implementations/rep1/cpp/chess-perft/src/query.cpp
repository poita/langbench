#include "chessperft/query.hpp"

#include <charconv>
#include <cstddef>
#include <cstdint>

#include "chessperft/fen.hpp"
#include "chessperft/perft.hpp"

namespace chessperft {

namespace {

std::optional<int> parseDepth(std::string_view text) {
  int value = 0;
  const auto [ptr, ec] = std::from_chars(text.data(), text.data() + text.size(), value);
  if (ec != std::errc{} || ptr != text.data() + text.size() || value < 0) {
    return std::nullopt;
  }
  return value;
}

}  // namespace

std::optional<Query> parseQuery(std::string_view line) {
  // The FEN is the first six space-separated fields.
  std::size_t end = 0;
  for (int fields = 0; fields < 6; ++fields) {
    end = line.find(' ', end);
    if (end == std::string_view::npos) return std::nullopt;
    if (fields < 5) ++end;
  }
  auto position = parseFen(line.substr(0, end));
  if (!position) return std::nullopt;

  Query query;
  query.position = *position;
  std::string_view rest = line.substr(end + 1);
  constexpr std::string_view kDivide = "divide ";
  if (rest.substr(0, kDivide.size()) == kDivide) {
    query.divide = true;
    rest.remove_prefix(kDivide.size());
  }
  const auto depth = parseDepth(rest);
  if (!depth || (query.divide && *depth < 1)) return std::nullopt;
  query.depth = *depth;
  return query;
}

std::string answerQuery(const Query& query) {
  if (!query.divide) return std::to_string(perft(query.position, query.depth)) + '\n';
  std::string out;
  std::uint64_t total = 0;
  for (const DivideEntry& e : divide(query.position, query.depth)) {
    out += e.move.toUci();
    out += ' ';
    out += std::to_string(e.nodes);
    out += '\n';
    total += e.nodes;
  }
  out += "total " + std::to_string(total) + '\n';
  return out;
}

}  // namespace chessperft
