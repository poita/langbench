// Strict UTF-8 validation (RFC 3629).
#pragma once

#include <string_view>

namespace protowire {

/// True if `s` is well-formed UTF-8: no overlong forms, no surrogates, nothing
/// above U+10FFFF, no truncated sequences. NUL bytes are allowed.
bool isValidUtf8(std::string_view s);

}  // namespace protowire
