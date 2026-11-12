#include "depresolve/version.hpp"

namespace depresolve {

namespace {

// Parses a decimal component starting at text[pos]; advances pos past it.
bool parse_component(std::string_view text, std::size_t& pos, Component& out) noexcept {
  const std::size_t start = pos;
  std::uint64_t value = 0;
  while (pos < text.size() && text[pos] >= '0' && text[pos] <= '9') {
    value = value * 10 + static_cast<std::uint64_t>(text[pos] - '0');
    if (value > kMaxComponent) return false;
    ++pos;
  }
  const std::size_t length = pos - start;
  if (length == 0) return false;
  if (length > 1 && text[start] == '0') return false;  // leading zero
  out = static_cast<Component>(value);
  return true;
}

}  // namespace

std::optional<Version> Version::parse(std::string_view text) noexcept {
  Version v;
  std::size_t pos = 0;
  if (!parse_component(text, pos, v.major)) return std::nullopt;
  if (pos >= text.size() || text[pos++] != '.') return std::nullopt;
  if (!parse_component(text, pos, v.minor)) return std::nullopt;
  if (pos >= text.size() || text[pos++] != '.') return std::nullopt;
  if (!parse_component(text, pos, v.patch)) return std::nullopt;
  if (pos != text.size()) return std::nullopt;
  return v;
}

std::string Version::to_string() const {
  return std::to_string(major) + '.' + std::to_string(minor) + '.' + std::to_string(patch);
}

}  // namespace depresolve
