// Canonical text form: formatting a value tree and parsing text into one.
#pragma once

#include <string>
#include <string_view>

#include "protowire/value.hpp"

namespace protowire {

/// Appends the canonical text of `message` (e.g. `{a: 1, b: "x"}`) to `out`.
void formatMessage(const Message& message, std::string& out);

/// Canonical text of `message`.
std::string formatMessage(const Message& message);

/// Parses a text-form message (relaxed grammar from SPEC.md: free spacing,
/// fields in any order, explicit defaults). Throws TextError.
Message parseMessage(const MessageDescriptor& descriptor, std::string_view text);

}  // namespace protowire
