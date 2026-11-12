#pragma once
/// \file render.hpp
/// Formatting of `results.txt` blocks (spec section 19).

#include <string>
#include <vector>

#include "tessera/database.hpp"

namespace tessera {

/// The result of one command: a status text and its payload lines.
struct Outcome {
  std::string status;  ///< e.g. `ok put created` or `error syntax`
  std::vector<std::string> payload;
};

/// `[k] status` followed by the payload lines, each indented two spaces and
/// each line terminated by LF.
std::string format_block(std::size_t line_no, const Outcome& outcome);

/// One line per entry: `"key" = doc`, or just `"key"` for keys-only entries.
std::vector<std::string> render_entries(const std::vector<Entry>& entries);
/// The nine `stat` lines.
std::vector<std::string> render_stats(const Stats& stats);
/// One line per live index.
std::vector<std::string> render_indexes(const std::vector<IndexInfo>& indexes);

}  // namespace tessera
