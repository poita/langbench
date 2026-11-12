#include "depresolve/output.hpp"

namespace depresolve {

std::string format_resolution(const std::optional<Resolution>& result) {
  if (!result) return "unsatisfiable\n";
  std::string out;
  for (const auto& p : result->packages) {
    out += p.name;
    out += ' ';
    out += p.version.to_string();
    out += '\n';
  }
  return out;
}

}  // namespace depresolve
