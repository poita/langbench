// The stdin/stdout contract: a schema, a `--` line, then one request per line.
#pragma once

#include <string>
#include <string_view>

#include "protowire/schema.hpp"

namespace protowire {

/// Handles a single request line (`decode <Name> <hex>` or
/// `encode <Name> <text>`) against `schema`. Returns the output line (without
/// newline); any malformed request yields "error". Never throws.
std::string handleRequest(const Schema& schema, std::string_view line);

/// Processes a whole input document (schema, `--`, requests) and returns the
/// output, one line per request, each terminated by '\n'. Never throws; an
/// unparseable schema produces "error" for every request.
std::string processInput(std::string_view input);

}  // namespace protowire
