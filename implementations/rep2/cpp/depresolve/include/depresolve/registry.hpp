// The package registry: every version of every package with its requirements.
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "depresolve/range.hpp"
#include "depresolve/version.hpp"

namespace depresolve {

/// Dense integer handle of a package name inside one Registry.
using PackageId = std::uint32_t;
/// Marks a requirement whose target package does not exist in the registry.
inline constexpr PackageId kNoPackage = ~PackageId{0};

/// A requirement as written: a package name and a version range.
struct Dependency {
  std::string name;
  Range range;
};

/// A requirement compiled against a finalized Registry.
///
/// `[first, last)` is the contiguous run of indices into
/// Registry::versions(package) (newest first) whose versions satisfy `range`.
/// Candidates for the requirement are therefore known without scanning.
struct Requirement {
  PackageId package = kNoPackage;
  Range range;
  std::uint32_t first = 0;
  std::uint32_t last = 0;

  bool has_candidates() const noexcept { return first < last; }
  /// True when the version at `index` (into Registry::versions) satisfies it.
  bool accepts_index(std::uint32_t index) const noexcept {
    return first <= index && index < last;
  }
};

/// One version of a package together with its compiled requirements.
struct PackageVersion {
  Version version;
  std::vector<Requirement> requirements;
};

/// Mutable while being filled with add_version(); call finalize() once all
/// versions are added to sort each package newest-first and compile every
/// requirement's candidate index range.
class Registry {
 public:
  /// Returns the id of `name`, creating an (empty) package if needed.
  PackageId intern(std::string_view name);
  /// Looks a name up without creating it.
  std::optional<PackageId> find(std::string_view name) const;

  /// Declares a package version. Requirements may name packages that are not
  /// (yet) declared. Invalidates finalize().
  void add_version(std::string_view name, Version version,
                   const std::vector<Dependency>& requirements);

  /// Sorts every package's versions newest first and resolves requirement
  /// ranges to index ranges (binary search). Idempotent.
  /// @throws std::invalid_argument if a (name, version) pair was added twice.
  void finalize();
  bool finalized() const noexcept { return finalized_; }

  std::size_t package_count() const noexcept { return packages_.size(); }
  const std::string& name(PackageId id) const { return packages_[id].name; }
  /// All versions of a package; newest first once finalized.
  const std::vector<PackageVersion>& versions(PackageId id) const {
    return packages_[id].versions;
  }

  /// Compiles a requirement (used for the root manifest). Unknown package
  /// names yield a requirement with package == kNoPackage and no candidates.
  /// @pre finalized()
  Requirement compile(const Dependency& dependency) const;
  std::vector<Requirement> compile(const std::vector<Dependency>& dependencies) const;

 private:
  struct Package {
    std::string name;
    std::vector<PackageVersion> versions;
  };

  void bind(Requirement& requirement) const;

  std::vector<Package> packages_;
  std::unordered_map<std::string, PackageId> index_;
  bool finalized_ = true;
};

}  // namespace depresolve
