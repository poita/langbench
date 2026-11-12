// toml/writer.hpp - Value tree -> canonical TOML text.
#pragma once

#include <string>
#include <string_view>

#include "toml/value.hpp"

namespace toml {

/// Writes the canonical TOML form of a table: plain pairs first, then
/// sub-tables and arrays of tables as headers, every level in ascending key
/// order, with a blank line before every header except one on the first line.
/// The output re-parses to an equal tree. `root` must be a table.
std::string to_toml(const Value& root);

/// A key as it appears in TOML: bare when possible, else a basic string.
std::string format_key(std::string_view key);

/// A basic string literal (with quotes) for `s`.
std::string quote_basic_string(std::string_view s);

}  // namespace toml
