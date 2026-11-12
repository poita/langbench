#include "regex/regex.hpp"

#include "regex/parser.hpp"

namespace regex {

Regex::Regex(std::string_view pattern) {
  ParseResult parsed = parse(pattern);
  program_ = std::make_shared<const Program>(compile(*parsed.root, parsed.group_count));
}

int Regex::group_count() const noexcept { return program_->group_count; }

std::optional<Match> Regex::search(std::string_view subject) const {
  Matcher matcher(*program_);
  Match m;
  if (!matcher.search(subject, m)) return std::nullopt;
  return m;
}

}  // namespace regex
