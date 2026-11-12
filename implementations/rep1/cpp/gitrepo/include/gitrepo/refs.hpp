// Reference lookup: HEAD, loose refs and packed-refs.
#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>

#include "gitrepo/object_id.hpp"

namespace gitrepo {

class RefDatabase {
 public:
  /// `git_dir` is the repository directory (holding HEAD, refs/ and
  /// packed-refs). packed-refs is read once, here.
  explicit RefDatabase(std::filesystem::path git_dir);

  /// Resolves one full ref name (`HEAD` or `refs/...`). A loose file wins over
  /// a packed entry; symbolic refs are followed at most 5 times. Returns
  /// nullopt if the name does not resolve. The object is not checked to exist.
  std::optional<ObjectId> resolve(std::string_view name) const;

 private:
  std::optional<ObjectId> resolve(std::string_view name, int symref_budget) const;

  std::filesystem::path git_dir_;
  std::unordered_map<std::string, ObjectId> packed_;
};

}  // namespace gitrepo
