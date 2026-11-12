// Tuple storage: a set of fixed-arity tuples with incrementally maintained
// hash indexes.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace datalog {

/// A constant, encoded as its rank in the sorted constant table, so that
/// comparing values compares constants.
using Value = std::uint32_t;
/// "No tuple" marker for tuple ids.
inline constexpr std::uint32_t kNone = 0xFFFFFFFFu;
/// Largest supported arity (column masks are 32 bits).
inline constexpr unsigned kMaxArity = 32;

class Relation;

/// Hash index over a subset of a relation's columns. Tuples with equal key
/// are chained in ascending id order, so a scan bounded by "id < limit" can
/// stop early. The index is brought up to date with sync(); it only ever
/// processes each tuple once, so maintenance is O(|relation|) over a whole run.
class Index {
 public:
  Index(const Relation& relation, std::uint32_t column_mask);

  std::uint32_t column_mask() const { return mask_; }
  /// Indexes every tuple added to the relation since the last call.
  void sync();
  /// First tuple whose indexed columns equal `key` (one value per indexed
  /// column, in ascending column order), or kNone.
  std::uint32_t first(const Value* key) const;
  /// Next tuple with the same key, or kNone.
  std::uint32_t next(std::uint32_t id) const { return next_[id]; }

 private:
  struct Slot {
    std::uint32_t head;
    std::uint32_t tail;
  };
  std::uint64_t hash_tuple(const Value* tuple) const;
  void grow();

  const Relation* relation_;
  std::uint32_t mask_;
  std::vector<unsigned> columns_;
  std::vector<Slot> slots_;
  std::size_t keys_ = 0;
  std::vector<std::uint32_t> next_;
};

/// A set of tuples of one arity. Tuples get dense ids 0, 1, 2, ... in
/// insertion order and are never removed.
class Relation {
 public:
  explicit Relation(unsigned arity);
  Relation(const Relation&) = delete;
  Relation& operator=(const Relation&) = delete;

  unsigned arity() const { return arity_; }
  std::size_t size() const { return count_; }
  /// Pointer to the tuple's values; invalidated by insert().
  const Value* tuple(std::uint32_t id) const {
    return data_.data() + static_cast<std::size_t>(id) * arity_;
  }

  /// Adds a tuple; returns false if it was already present.
  bool insert(const Value* tuple);
  /// Id of the tuple, or kNone.
  std::uint32_t find(const Value* tuple) const;
  bool contains(const Value* tuple) const { return find(tuple) != kNone; }

  /// The index on the given non-empty column set (bit i = column i), created
  /// on demand and brought up to date.
  Index& index(std::uint32_t column_mask);
  /// Brings every existing index up to date.
  void sync_indexes();

 private:
  void grow();

  unsigned arity_;
  std::size_t count_ = 0;
  std::vector<Value> data_;
  std::vector<std::uint32_t> table_;  // open addressing, ids
  std::vector<std::unique_ptr<Index>> indexes_;
};

}  // namespace datalog
