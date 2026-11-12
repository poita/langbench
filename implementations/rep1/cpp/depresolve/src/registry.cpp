#include "depresolve/registry.hpp"

#include <utility>

namespace depresolve {

PackageId Registry::intern(std::string_view name) {
  std::string key(name);
  auto it = ids_.find(key);
  if (it != ids_.end()) return it->second;
  PackageId id = static_cast<PackageId>(names_.size());
  names_.push_back(key);
  ids_.emplace(std::move(key), id);
  return id;
}

std::optional<PackageId> Registry::find(std::string_view name) const {
  auto it = ids_.find(std::string(name));
  if (it == ids_.end()) return std::nullopt;
  return it->second;
}

void Registry::add_version(PackageId package, const Version& version,
                           std::vector<Requirement> requirements) {
  versions_.push_back(PackageVersion{package, version, std::move(requirements)});
}

}  // namespace depresolve
