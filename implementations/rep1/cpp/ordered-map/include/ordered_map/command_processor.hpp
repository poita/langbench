// command_processor.hpp - the text command protocol on top of OrderedMap.
#pragma once

#include <string>
#include <string_view>

#include "ordered_map/ordered_map.hpp"

namespace ordered_map {

/// Executes one command line against `map`, appending exactly one output line
/// (including the trailing '\n') to `out`.
///
/// Commands: insert K V | delete K | get K | size | min | max | floor K |
/// ceil K | succ K | pred K | rank K | select N | range LO HI.
///
/// Returns false (appending nothing) if the line is not a valid command.
bool execute_command(OrderedMap& map, std::string_view line, std::string& out);

/// Runs a whole script: the first line is the command count Q, followed by Q
/// command lines. Output lines are appended to `out`.
/// Returns false if the script is malformed (output produced so far is kept).
bool run_script(std::string_view input, std::string& out);

}  // namespace ordered_map
