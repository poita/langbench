#include "depresolve/registry.hpp"

#include <algorithm>
#include <stdexcept>

namespace depresolve {

PackageId Registry::intern(std::string_view name) {
  std::string key(name);
  const auto it = index_.find(key);
  if (it != index_.end()) return it->second;
  const auto id = static_cast<PackageId>(packages_.size());
  packages_.push_back(Package{key, {}});
  index_.emplace(std::move(key), id);
  return id;
}

std::optional<PackageId> Registry::find(std::string_view name) const {
  const auto it = index_.find(std::string(name));
  if (it == index_.end()) return std::nullopt;
  return it->second;
}

void Registry::add_version(std::string_view name, Version version,
                           const std::vector<Dependency>& requirements) {
  PackageVersion entry;
  entry.version = version;
  entry.requirements.reserve(requirements.size());
  for (const Dependency& dep : requirements) {
    Requirement r;
    r.package = intern(dep.name);
    r.range = dep.range;
    entry.requirements.push_back(r);
  }
  const PackageId id = intern(name);  // after the loop: intern may reallocate packages_
  packages_[id].versions.push_back(std::move(entry));
  finalized_ = false;
}

void Registry::finalize() {
  if (finalized_) return;
  for (Package& package : packages_) {
    auto& versions = package.versions;
    std::sort(versions.begin(), versions.end(),
              [](const PackageVersion& a, const PackageVersion& b) { return a.version > b.version; });
    const auto dup = std::adjacent_find(
        versions.begin(), versions.end(),
        [](const PackageVersion& a, const PackageVersion& b) { return a.version == b.version; });
    if (dup != versions.end()) {
      throw std::invalid_argument("duplicate version " + package.name + " " +
                                  dup->version.to_string());
    }
  }
  finalized_ = true;  // bind() reads sorted version lists only
  for (Package& package : packages_) {
    for (PackageVersion& pv : package.versions) {
      for (Requirement& r : pv.requirements) bind(r);
    }
  }
}

// Fills r.first/r.last from r.package and r.range. Versions are sorted newest
// first, so the versions >= lower and < upper form one contiguous run.
void Registry::bind(Requirement& r) const {
  r.first = r.last = 0;
  if (r.package == kNoPackage) return;
  const auto& versions = packages_[r.package].versions;
  const Range& range = r.range;
  // First index whose version is below `upper` (skips versions >= upper).
  const auto begin = std::partition_point(
      versions.begin(), versions.end(),
      [&](const PackageVersion& pv) { return !(pv.version < range.upper()); });
  // First index whose version is below `lower`.
  const auto end = std::partition_point(
      versions.begin(), versions.end(),
      [&](const PackageVersion& pv) { return !(pv.version < range.lower()); });
  r.first = static_cast<std::uint32_t>(begin - versions.begin());
  r.last = std::max(r.first, static_cast<std::uint32_t>(end - versions.begin()));
}

Requirement Registry::compile(const Dependency& dependency) const {
  if (!finalized_) throw std::logic_error("Registry::compile requires finalize()");
  Requirement r;
  const auto id = find(dependency.name);
  r.package = id ? *id : kNoPackage;
  r.range = dependency.range;
  bind(r);
  return r;
}

std::vector<Requirement> Registry::compile(const std::vector<Dependency>& dependencies) const {
  std::vector<Requirement> out;
  out.reserve(dependencies.size());
  for (const Dependency& d : dependencies) out.push_back(compile(d));
  return out;
}

}  // namespace depresolve
