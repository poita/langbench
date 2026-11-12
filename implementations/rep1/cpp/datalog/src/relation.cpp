#include "datalog/relation.h"

#include <algorithm>
#include <cstring>

namespace datalog {

std::uint64_t hash_values(const Value* values, std::size_t n) {
  std::uint64_t h = 0x9E3779B97F4A7C15ull ^ n;
  for (std::size_t i = 0; i < n; ++i) {
    h ^= static_cast<std::uint64_t>(values[i]) + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2);
    h *= 0xFF51AFD7ED558CCDull;
    h ^= h >> 32;
  }
  h *= 0xC4CEB9FE1A85EC53ull;
  h ^= h >> 29;
  return h;
}

namespace {
std::size_t pow2_at_least(std::size_t n, std::size_t minimum) {
  std::size_t c = minimum;
  while (c < n) c <<= 1;
  return c;
}
}  // namespace

// ---- Index ----------------------------------------------------------------

Index::Index(std::uint32_t mask, std::size_t arity) : mask_(mask) {
  for (std::uint32_t c = 0; c < arity; ++c)
    if (mask & (1u << c)) cols_.push_back(c);
}

std::uint64_t Index::key_hash(const Value* tuple) const {
  Value key[32];
  std::size_t k = 0;
  for (std::uint32_t c : cols_) key[k++] = tuple[c];
  return hash_values(key, k);
}

void Index::rebuild(const Relation& rel, std::size_t capacity) {
  heads_.assign(pow2_at_least(capacity, 16), kNoTuple);
  next_.resize(rel.size(), kNoTuple);
  // Ascending insertion at the chain head leaves every chain newest-first.
  for (TupleId id = 0; id < rel.size(); ++id) {
    std::size_t b = key_hash(rel.tuple(id)) & (heads_.size() - 1);
    next_[id] = heads_[b];
    heads_[b] = static_cast<TupleId>(id);
  }
}

void Index::add(const Relation& rel, TupleId id) {
  // `rel` already contains tuple `id`.
  if (rel.size() > heads_.size()) {
    rebuild(rel, rel.size() * 2);
    return;
  }
  next_.resize(rel.size(), kNoTuple);
  std::size_t b = key_hash(rel.tuple(id)) & (heads_.size() - 1);
  next_[id] = heads_[b];
  heads_[b] = id;
}

// ---- Relation -------------------------------------------------------------

Relation::Relation(std::size_t arity) : arity_(arity), table_(16, kNoTuple) {}

std::size_t Relation::find_slot(const Value* t, std::uint64_t h) const {
  const std::size_t mask = table_.size() - 1;
  std::size_t s = h & mask;
  while (table_[s] != kNoTuple &&
         std::memcmp(tuple(table_[s]), t, arity_ * sizeof(Value)) != 0) {
    s = (s + 1) & mask;
  }
  return s;
}

bool Relation::contains(const Value* t) const {
  return table_[find_slot(t, hash_values(t, arity_))] != kNoTuple;
}

void Relation::grow_table() {
  table_.assign(table_.size() * 2, kNoTuple);
  const std::size_t mask = table_.size() - 1;
  for (TupleId id = 0; id < count_; ++id) {
    std::size_t s = hash_values(tuple(id), arity_) & mask;
    while (table_[s] != kNoTuple) s = (s + 1) & mask;
    table_[s] = id;
  }
}

bool Relation::insert(const Value* t) {
  std::uint64_t h = hash_values(t, arity_);
  std::size_t s = find_slot(t, h);
  if (table_[s] != kNoTuple) return false;
  TupleId id = static_cast<TupleId>(count_);
  data_.insert(data_.end(), t, t + arity_);
  ++count_;
  table_[s] = id;
  if (count_ * 2 > table_.size()) grow_table();
  for (auto& idx : indexes_) idx->add(*this, id);
  return true;
}

const Index& Relation::index(std::uint32_t mask) {
  for (auto& idx : indexes_)
    if (idx->mask() == mask) return *idx;
  indexes_.emplace_back(new Index(mask, arity_));
  indexes_.back()->rebuild(*this, count_);
  return *indexes_.back();
}

}  // namespace datalog
