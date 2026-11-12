// Parsed forms of commits, trees and tags.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "gitrepo/object_id.hpp"
#include "gitrepo/object_store.hpp"

namespace gitrepo {

/// The name and timestamp of an `author` / `committer` / `tagger` line.
struct Ident {
  std::string name;
  std::uint64_t timestamp = 0;
};

struct Commit {
  ObjectId tree;
  std::vector<ObjectId> parents;
  Ident author;
  Ident committer;
  std::string message;  ///< everything after the first empty line
  std::string subject;  ///< see SPEC.md: first paragraph folded onto one line
};

struct TreeEntry {
  std::uint32_t mode = 0;
  std::string name;
  ObjectId id;

  /// Decided by the high bits of the mode: tree, commit (gitlink) or blob.
  ObjectType type() const;
  bool is_tree() const { return (mode & 0170000) == 0040000; }
};

struct Tree {
  std::vector<TreeEntry> entries;  ///< in stored order
};

struct Tag {
  ObjectId target;
};

/// Each parser throws Error when the payload is malformed.
Commit parse_commit(std::string_view payload);
Tree parse_tree(std::string_view payload);
Tag parse_tag(std::string_view payload);

/// Computes a commit subject from a raw message.
std::string commit_subject(std::string_view message);

}  // namespace gitrepo
