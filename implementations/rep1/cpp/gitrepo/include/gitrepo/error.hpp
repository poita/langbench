// Error type shared by every gitrepo module.
#pragma once

#include <stdexcept>
#include <string>

namespace gitrepo {

/// Thrown for every recoverable failure: a missing or damaged object, an
/// unresolvable revision, a malformed argument and so on. Callers that only
/// care about success or failure can catch this single type.
class Error : public std::runtime_error {
 public:
  explicit Error(const std::string& what) : std::runtime_error(what) {}
};

}  // namespace gitrepo
