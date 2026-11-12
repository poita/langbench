#include "rx/regex.hpp"

namespace rx {

Regex::Regex(std::string_view pattern)
    : program_(std::make_shared<const Program>(compile(parse(pattern)))) {}

std::optional<Match> Regex::search(std::string_view subject) const {
  Matcher m(*program_);
  Match out;
  if (!m.search(subject, out)) return std::nullopt;
  return out;
}

}  // namespace rx
