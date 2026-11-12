// The virtual file system: a flat map from workspace path to file content.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace kiln {

/// An in-memory workspace. Content is immutable and shared, so reading a file
/// is O(1); each distinct content is hashed at most once.
class Vfs {
 public:
  using Content = std::shared_ptr<const std::string>;

  bool exists(std::string_view path) const;

  /// The file's content, or null when there is no such file.
  Content read(std::string_view path) const;

  /// FNV-1a-64 of the file's content (cached). The file must exist.
  std::uint64_t hash(std::string_view path) const;

  /// Creates or replaces a file.
  void write(std::string_view path, std::string content);
  void write(std::string_view path, Content content);

  /// Removes a file; returns whether it existed.
  bool remove(std::string_view path);

  /// Updates the file's modification stamp. Never consulted by the build.
  void touch(std::string_view path);
  std::uint64_t stamp(std::string_view path) const;

  std::size_t size() const { return files_.size(); }

  /// Every path, ascending.
  std::vector<std::string> paths() const;

  /// Paths whose first component is `out`, plus `.kiln-state` if present, ascending.
  std::vector<std::string> generated_paths() const;

  /// Glob-eligible paths (not generated, not the state file) that start with
  /// `prefix`, ascending. O(log F + result).
  std::vector<std::string> eligible_with_prefix(std::string_view prefix) const;

  /// Loads every regular file below `dir`, except a top-level `skip_top_level`.
  static Vfs load_directory(const std::string& dir, std::string_view skip_top_level = {});

  /// Writes every file under `dir`, creating intermediate directories.
  void save_directory(const std::string& dir) const;

 private:
  struct File {
    Content content;
    mutable std::optional<std::uint64_t> hash;
    std::uint64_t stamp = 0;
  };

  static bool is_eligible(std::string_view path);

  std::map<std::string, File, std::less<>> files_;
  std::set<std::string, std::less<>> eligible_;
  std::uint64_t clock_ = 0;
};

}  // namespace kiln
