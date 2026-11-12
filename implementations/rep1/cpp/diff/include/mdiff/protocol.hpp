// The line-oriented request/response format used by the command-line tool.
#pragma once

#include <stdexcept>
#include <string>
#include <string_view>

namespace mdiff {

class ProtocolError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

/// Processes one request and returns the response text.
///
/// Request: the mode line ("diff" or "patch"), then a count N and N lines of
/// A, then (diff) a count M and M lines of B, or (patch) a count K and K
/// script lines. Lines are read strictly by the declared counts. Response:
/// the count of output lines followed by those lines, each '\n'-terminated.
///
/// Throws ProtocolError (malformed input) or ScriptError (invalid script).
std::string process_request(std::string_view input);

}  // namespace mdiff
