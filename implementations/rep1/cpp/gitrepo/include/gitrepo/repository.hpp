// A repository: object store, refs and caches of parsed objects.
#pragma once

#include <filesystem>
#include <memory>
#include <unordered_map>

#include "gitrepo/object_id.hpp"
#include "gitrepo/object_store.hpp"
#include "gitrepo/objects.hpp"
#include "gitrepo/refs.hpp"

namespace gitrepo {

/// Read-only view of a git repository directory (a `.git` directory or a bare
/// repository).
///
/// One Repository answers any number of queries; pack data, parsed commits
/// and parsed trees are decoded at most once and kept.
class Repository {
 public:
  explicit Repository(const std::filesystem::path& git_dir);

  ObjectStore& objects() { return store_; }
  const RefDatabase& refs() const { return refs_; }

  /// Parsed commit `id`. Throws Error if missing, damaged or not a commit.
  const Commit& commit(const ObjectId& id);
  /// Parsed tree `id`. Throws Error if missing, damaged or not a tree.
  const Tree& tree(const ObjectId& id);

 private:
  ObjectStore store_;
  RefDatabase refs_;
  std::unordered_map<ObjectId, std::unique_ptr<Commit>, ObjectIdHash> commits_;
  std::unordered_map<ObjectId, std::unique_ptr<Tree>, ObjectIdHash> trees_;
};

}  // namespace gitrepo
