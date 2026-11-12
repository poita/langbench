#include "depresolve/version.hpp"

namespace depresolve {

namespace {

// Parses one component from the front of `text`, advancing it.
bool parse_component(std::string_view& text, std::uint32_t& out) {
  if (text.empty() || text[0] < '0' || text[0] > '9') return false;
  if (text[0] == '0' && text.size() > 1 && text[1] >= '0' && text[1] <= '9') return false;
  std::uint64_t value = 0;
  std::size_t i = 0;
  while (i < text.size() && text[i] >= '0' && text[i] <= '9') {
    value = value * 10 + static_cast<std::uint64_t>(text[i] - '0');
    if (value > kMaxVersionComponent) return false;
    ++i;
  }
  out = static_cast<std::uint32_t>(value);
  text.remove_prefix(i);
  return true;
}

}  // namespace

std::optional<Version> Version::parse(std::string_view text) {
  Version v;
  if (!parse_component(text, v.major)) return std::nullopt;
  if (text.empty() || text[0] != '.') return std::nullopt;
  text.remove_prefix(1);
  if (!parse_component(text, v.minor)) return std::nullopt;
  if (text.empty() || text[0] != '.') return std::nullopt;
  text.remove_prefix(1);
  if (!parse_component(text, v.patch)) return std::nullopt;
  if (!text.empty()) return std::nullopt;
  return v;
}

std::string Version::to_string() const {
  return std::to_string(major) + '.' + std::to_string(minor) + '.' + std::to_string(patch);
}

}  // namespace depresolve
