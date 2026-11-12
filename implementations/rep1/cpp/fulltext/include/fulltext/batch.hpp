/// @file batch.hpp
/// The batch ("directory mode") front end: the `queries.txt` file format and
/// the `results.txt` / `stats.txt` output formats.
#pragma once

#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

#include "fulltext/index.hpp"
#include "fulltext/searcher.hpp"

namespace fulltext {

/// One query line together with its number and the `k` in force.
struct QueryEntry {
  std::size_t number;  ///< 1-based.
  std::string text;    ///< Stripped line, echoed verbatim in the output.
  std::size_t k;
};

/// Result limit in force before any `%k` directive.
inline constexpr std::size_t kDefaultK = 10;

/// Parses the contents of `queries.txt`: skips blank lines and `#` comments,
/// applies `%k <n>` directives to the queries after them, and numbers the rest.
std::vector<QueryEntry> parse_query_file(std::string_view contents);

/// Runs all entries and returns the text of `results.txt`.
std::string format_results(const Searcher& searcher, const std::vector<QueryEntry>& queries);

/// Returns the text of `stats.txt`.
std::string format_stats(const Index& index);

/// Whole job: reads `<input_dir>/docs` and `<input_dir>/queries.txt`, writes
/// `results.txt` and `stats.txt` into `output_dir` (created if missing).
/// Throws `std::runtime_error` on I/O failure.
void run_directory(const std::filesystem::path& input_dir, const std::filesystem::path& output_dir);

}  // namespace fulltext
