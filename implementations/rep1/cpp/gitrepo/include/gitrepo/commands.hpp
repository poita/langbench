// The query commands of the command-line tool, as a library function.
#pragma once

#include <string>
#include <string_view>

#include "gitrepo/repository.hpp"

namespace gitrepo {

/// Runs one command line (`log main 5`, `ls-tree HEAD src`, `cat-file <rev>`,
/// `diff <rev> <rev>`, `rev-parse <rev>`, `count-objects`) and returns its
/// output. The line is split on single spaces only. Throws Error when the
/// command fails for any reason.
std::string run_command(Repository& repo, std::string_view line);

/// Like run_command, but a failure yields the text "error\n".
std::string run_command_or_error(Repository& repo, std::string_view line);

}  // namespace gitrepo
