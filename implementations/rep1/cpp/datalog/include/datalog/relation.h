// Relations: append-only tuple sets with incrementally maintained hash indexes.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

#include "datalog/value.h"

namespace datalog {

using TupleId = std::uint32_t;
inline constexpr TupleId kNoTuple = 0xFFFFFFFFu;

/// Hash of `n` consecutive values.
std::uint64_t hash_values(const Value* values, std::size_t n);

class Relation;

/// A hash index over a subset of a relation's columns (the "access pattern",
/// given as a bit mask: bit i set = column i is part of the key).
///
/// Tuples with equal key hash are chained, newest (highest id) first, so a
/// scan can skip tuples that are too new and stop at tuples that are too old.
/// A chain may mix keys that collide; callers must compare the key columns.
class Index {
 public:
  std::uint32_t mask() const { return mask_; }
  const std::vector<std::uint32_t>& columns() const { return cols_; }

  /// First tuple id of the chain for key hash `h`, or kNoTuple.
  TupleId head(std::uint64_t h) const { return heads_[h & (heads_.size() - 1)]; }
  /// Next (older) tuple id in the chain, or kNoTuple.
  TupleId next(TupleId id) const { return next_[id]; }

 private:
  friend class Relation;
  Index(std::uint32_t mask, std::size_t arity);

  std::uint64_t key_hash(const Value* tuple) const;
  void rebuild(const Relation& rel, std::size_t capacity);
  void add(const Relation& rel, TupleId id);

  std::uint32_t mask_;
  std::vector<std::uint32_t> cols_;
  std::vector<TupleId> heads_;
  std::vector<TupleId> next_;
};

/// A set of fixed-arity tuples. Tuples are numbered 0, 1, 2, ... in
/// insertion order and never removed, so id ranges identify "generations"
/// (e.g. the tuples added in one evaluation round).
class Relation {
 public:
  explicit Relation(std::size_t arity);
  Relation(Relation&&) = default;
  Relation& operator=(Relation&&) = default;

  std::size_t arity() const { return arity_; }
  std::size_t size() const { return count_; }

  /// Pointer to the `arity()` values of tuple `id`. Invalidated by insert().
  const Value* tuple(TupleId id) const { return data_.data() + std::size_t{id} * arity_; }

  /// Adds a tuple; returns false if it was already present.
  bool insert(const Value* tuple);
  bool contains(const Value* tuple) const;

  /// Returns the index for `mask`, building it over the current tuples if
  /// needed. Afterwards it is kept up to date by insert(). The reference
  /// stays valid for the lifetime of the relation.
  const Index& index(std::uint32_t mask);

 private:
  std::size_t find_slot(const Value* tuple, std::uint64_t h) const;
  void grow_table();

  std::size_t arity_;
  std::size_t count_ = 0;
  std::vector<Value> data_;
  std::vector<TupleId> table_;  // open-addressing set of tuple ids
  std::vector<std::unique_ptr<Index>> indexes_;
};

}  // namespace datalog
