// git-style C quoting of path names.
#pragma once

#include <string>
#include <string_view>

namespace gitrepo {

/// Returns `name` unchanged when every byte is printable ASCII other than `"`
/// and `\`; otherwise a double-quoted, backslash-escaped form (non-ASCII bytes
/// become three-digit octal escapes).
std::string quote_path(std::string_view name);

}  // namespace gitrepo
