/// \file registry.hpp
/// The package registry: every version of every package with its requirements.
#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "depresolve/range.hpp"
#include "depresolve/version.hpp"

namespace depresolve {

/// Dense identifier of a package name within one Registry.
using PackageId = std::uint32_t;

/// "package must be picked at a version inside range".
struct Requirement {
  PackageId package;
  Range range;
};

/// One registry entry: a version of a package and what it requires, in the
/// order the requirements were written (the order matters to the search).
struct PackageVersion {
  PackageId package;
  Version version;
  std::vector<Requirement> requirements;
};

/// Container for package versions. Names are interned to PackageIds; a name
/// that only occurs inside requirements has an id but no versions.
class Registry {
 public:
  /// Returns the id of `name`, creating it if needed.
  PackageId intern(std::string_view name);

  /// Returns the id of `name` if known.
  std::optional<PackageId> find(std::string_view name) const;

  /// The name behind an id.
  const std::string& name(PackageId id) const { return names_[id]; }

  /// Number of distinct package names seen (declared or merely required).
  std::size_t package_count() const { return names_.size(); }

  /// Declares a package version. Versions may be added in any order.
  void add_version(PackageId package, const Version& version, std::vector<Requirement> requirements);

  /// All declared versions, in insertion order.
  std::span<const PackageVersion> versions() const { return versions_; }

 private:
  std::vector<std::string> names_;
  std::unordered_map<std::string, PackageId> ids_;
  std::vector<PackageVersion> versions_;
};

}  // namespace depresolve
