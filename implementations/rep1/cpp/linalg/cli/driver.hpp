#pragma once
/// \file driver.hpp
/// The script driver behind the `linalg_cli` executable: reads `commands.txt`
/// and matrix files from a directory, writes one result per command.

#include <filesystem>
#include <string>
#include <vector>

namespace linalg::cli {

/// Splits `commands.txt` text into commands: lines are stripped, blank lines
/// and `#` comments dropped, the rest split on spaces/tabs.
std::vector<std::vector<std::string>> parse_script(const std::string& text);

/// Runs every command of `<input_dir>/commands.txt`, writing results to
/// `output_dir`. A command that fails with a library Error writes
/// `NNN_error.txt`. Per-command problems that are not library errors
/// (unknown operation, missing file, ...) are reported on stderr and skipped.
/// Returns the number of commands processed.
std::size_t run_script(const std::filesystem::path& input_dir, const std::filesystem::path& output_dir);

}  // namespace linalg::cli
