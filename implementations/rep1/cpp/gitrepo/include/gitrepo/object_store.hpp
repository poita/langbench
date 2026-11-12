// Reading objects out of a repository's object database.
#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "gitrepo/object_id.hpp"

namespace gitrepo {

enum class ObjectType { Commit = 1, Tree = 2, Blob = 3, Tag = 4 };

/// "commit", "tree", "blob" or "tag".
std::string_view type_name(ObjectType type);

/// A fully reconstructed object: its type and its payload bytes.
struct Object {
  ObjectType type;
  std::string data;
};
using ObjectPtr = std::shared_ptr<const Object>;

/// The id of an object, computed from its stored form `<type> <size>\0<data>`.
ObjectId hash_object(ObjectType type, std::string_view data);

/// A parsed pack index (version 2). Holds the whole file in memory.
class PackIndex {
 public:
  /// Returns nullopt if `bytes` is not a well-formed version 2 index.
  static std::optional<PackIndex> parse(std::string bytes);

  /// Number of objects in the index (`fanout[255]`).
  std::uint32_t size() const { return count_; }

  /// The i-th id in ascending order. Requires i < size().
  ObjectId id_at(std::uint32_t i) const;

  /// Position of the first id that is >= `key`, in O(log N).
  std::uint32_t lower_bound(const ObjectId& key) const;

  /// Pack offset of the object `id`, if the index lists it.
  std::optional<std::uint64_t> find(const ObjectId& id) const;

 private:
  std::uint32_t fanout(int b) const;
  std::uint32_t read32(std::size_t pos) const;

  std::string bytes_;
  std::uint32_t count_ = 0;
};

/// The object database: loose objects plus every pack with a matching index.
///
/// The set of loose objects and all pack indexes and packs are read once, when
/// the store is constructed. Objects reconstructed from packs (including
/// delta bases) are cached for the lifetime of the store.
class ObjectStore {
 public:
  /// `objects_dir` is `<repo>/objects`. A missing directory is an empty store.
  explicit ObjectStore(const std::filesystem::path& objects_dir);

  /// True if the id is a loose file or listed in a pack index. Does not read
  /// or validate the object.
  bool contains(const ObjectId& id) const;

  /// Reads and decompresses an object (loose copy first, then packs in name
  /// order). Throws Error when it is missing or damaged.
  ObjectPtr read(const ObjectId& id);

  /// Ids of at most `limit` distinct objects whose hex id starts with
  /// `lower_hex_prefix` (1 to 40 lowercase hex digits). Loose and packed
  /// copies of one id count once. O(log N) per index.
  std::vector<ObjectId> find_by_prefix(std::string_view lower_hex_prefix,
                                       std::size_t limit = 2) const;

  /// Number of loose object files (`objects/xx/<38 hex>`).
  std::size_t loose_count() const { return loose_.size(); }
  /// Number of packs (an index with a matching pack file).
  std::size_t pack_count() const { return packs_.size(); }
  /// Sum of the object counts of all pack indexes.
  std::size_t packed_object_count() const;

 private:
  struct Pack {
    PackIndex index;
    std::string data;
  };

  ObjectPtr read_loose(const ObjectId& id) const;
  ObjectPtr read_packed(std::size_t pack, std::uint64_t offset);

  std::filesystem::path objects_dir_;
  int depth_ = 0;                // current delta recursion depth
  std::vector<ObjectId> loose_;  // sorted
  std::vector<Pack> packs_;      // sorted by file name
  std::unordered_map<ObjectId, ObjectPtr, ObjectIdHash> cache_;
  std::map<std::pair<std::size_t, std::uint64_t>, ObjectPtr> pack_cache_;
};

/// Applies a git delta to `base`. Throws Error if the delta is malformed or
/// inconsistent with the base.
std::string apply_delta(std::string_view base, std::string_view delta);

}  // namespace gitrepo
