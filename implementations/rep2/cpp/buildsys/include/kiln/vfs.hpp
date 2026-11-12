// The virtual file system: a flat map from workspace path to content.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "kiln/glob.hpp"

namespace kiln {

/// Immutable, shared file content.
using Content = std::shared_ptr<const std::string>;

/// An in-memory workspace. Each file's content hash is computed at most once
/// per distinct content (it is cached until the file is rewritten).
class Vfs {
 public:
  /// True if a file exists at `path`.
  bool exists(const std::string& path) const;

  /// The file's content, or nullptr if absent.
  Content read(const std::string& path) const;

  /// FNV-1a hash of the file's content (cached). The file must exist.
  std::uint64_t hash(const std::string& path) const;

  /// Creates or replaces a file.
  void write(const std::string& path, std::string content);
  void write(const std::string& path, Content content);

  /// Removes a file; returns whether it existed.
  bool remove(const std::string& path);

  /// Updates the modification stamp. Stamps never influence Kiln's decisions.
  void touch(const std::string& path);

  /// Workspace paths matched by `pattern`, sorted ascending. Generated paths
  /// (`out/...`) and `.kiln-state` are never returned. Cost is O(log F) plus
  /// the paths sharing the pattern's literal prefix.
  std::vector<std::string> glob(const GlobPattern& pattern) const;

  /// All paths that `clean` removes (`out/...` and `.kiln-state`), sorted.
  std::vector<std::string> generatedPaths() const;

  /// Every path with its content, sorted by path.
  template <typename F>
  void forEach(F&& f) const {
    for (const auto& [path, e] : files_) f(path, *e.content);
  }

  std::size_t size() const noexcept { return files_.size(); }

  /// Loads a real directory tree, skipping a top-level `skipName` file.
  static Vfs loadDirectory(const std::string& dir, const std::string& skipName = {});

  /// Writes every file below `dir` (creating directories as needed).
  void writeDirectory(const std::string& dir) const;

 private:
  struct Entry {
    Content content;
    mutable bool hashed = false;
    mutable std::uint64_t hash = 0;
    std::uint64_t stamp = 0;
  };
  static bool globEligible(const std::string& path);

  std::map<std::string, Entry> files_;
  std::set<std::string> globIndex_;  // eligible paths, sorted
  std::uint64_t clock_ = 0;
};

}  // namespace kiln
