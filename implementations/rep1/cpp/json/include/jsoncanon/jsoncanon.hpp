// Umbrella header and one-call convenience API.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "jsoncanon/parser.hpp"
#include "jsoncanon/serializer.hpp"
#include "jsoncanon/utf8.hpp"
#include "jsoncanon/value.hpp"

namespace jsoncanon {

/// Parses `input` and returns its canonical serialization, or std::nullopt if
/// it is not a valid document.
std::optional<std::string> canonicalize(std::string_view input, const ParseOptions& options = {});

}  // namespace jsoncanon
