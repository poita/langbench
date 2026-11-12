#pragma once
/// \file executor.hpp
/// Runs command lines against a database and produces `results.txt`.

#include <string>
#include <string_view>

#include "tessera/command.hpp"
#include "tessera/database.hpp"
#include "tessera/render.hpp"

namespace tessera {

/// Executes one parsed command. Throws `Error` on failure.
Outcome execute(Database& db, const Command& command);

/// Parses and executes one line; failures become `error <kind>` outcomes.
Outcome run_line(Database& db, std::string_view line);

/// Splits a script into command lines: at each LF, where a trailing LF
/// terminates the last line (so an empty script has no lines).
std::vector<std::string_view> split_lines(std::string_view script);

/// Runs a whole script and returns the text of `results.txt`. A transaction
/// still open at the end is rolled back.
std::string run_script(Database& db, std::string_view script);

}  // namespace tessera
