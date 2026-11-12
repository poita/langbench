#include "datalog/relation.h"

#include <cassert>

namespace datalog {
namespace {

inline std::uint64_t mix(std::uint64_t h, std::uint64_t v) {
  h ^= v + 0x9E3779B97F4A7C15ull + (h << 6) + (h >> 2);
  h *= 0xFF51AFD7ED558CCDull;
  h ^= h >> 32;
  return h;
}

inline std::uint64_t hash_all(const Value* t, unsigned n) {
  std::uint64_t h = 0x243F6A8885A308D3ull;
  for (unsigned i = 0; i < n; ++i) h = mix(h, t[i]);
  return h;
}

}  // namespace

// ---------------------------------------------------------------- Index

Index::Index(const Relation& relation, std::uint32_t column_mask)
    : relation_(&relation), mask_(column_mask) {
  assert(column_mask != 0);
  for (unsigned c = 0; c < relation.arity(); ++c)
    if (column_mask & (1u << c)) columns_.push_back(c);
  slots_.assign(16, Slot{kNone, kNone});
}

std::uint64_t Index::hash_tuple(const Value* tuple) const {
  std::uint64_t h = 0x243F6A8885A308D3ull;
  for (unsigned c : columns_) h = mix(h, tuple[c]);
  return h;
}

void Index::grow() {
  std::vector<Slot> old = std::move(slots_);
  slots_.assign(old.size() * 2, Slot{kNone, kNone});
  std::size_t m = slots_.size() - 1;
  for (const Slot& s : old) {
    if (s.head == kNone) continue;
    std::size_t i = hash_tuple(relation_->tuple(s.head)) & m;
    while (slots_[i].head != kNone) i = (i + 1) & m;
    slots_[i] = s;
  }
}

void Index::sync() {
  std::size_t n = relation_->size();
  next_.reserve(n);
  for (std::size_t id = next_.size(); id < n; ++id) {
    next_.push_back(kNone);
    const Value* t = relation_->tuple(static_cast<std::uint32_t>(id));
    std::size_t m = slots_.size() - 1;
    std::size_t i = hash_tuple(t) & m;
    for (;;) {
      Slot& s = slots_[i];
      if (s.head == kNone) {
        s.head = s.tail = static_cast<std::uint32_t>(id);
        if (++keys_ * 2 > slots_.size()) grow();
        break;
      }
      const Value* h = relation_->tuple(s.head);
      bool same = true;
      for (unsigned c : columns_)
        if (h[c] != t[c]) { same = false; break; }
      if (same) {
        next_[s.tail] = static_cast<std::uint32_t>(id);
        s.tail = static_cast<std::uint32_t>(id);
        break;
      }
      i = (i + 1) & m;
    }
  }
}

std::uint32_t Index::first(const Value* key) const {
  std::uint64_t h = 0x243F6A8885A308D3ull;
  std::size_t k = columns_.size();
  for (std::size_t j = 0; j < k; ++j) h = mix(h, key[j]);
  std::size_t m = slots_.size() - 1;
  for (std::size_t i = h & m;; i = (i + 1) & m) {
    const Slot& s = slots_[i];
    if (s.head == kNone) return kNone;
    const Value* t = relation_->tuple(s.head);
    bool same = true;
    for (std::size_t j = 0; j < k; ++j)
      if (t[columns_[j]] != key[j]) { same = false; break; }
    if (same) return s.head;
  }
}

// ------------------------------------------------------------- Relation

Relation::Relation(unsigned arity) : arity_(arity) {
  table_.assign(16, kNone);
}

void Relation::grow() {
  std::vector<std::uint32_t> old = std::move(table_);
  table_.assign(old.size() * 2, kNone);
  std::size_t m = table_.size() - 1;
  for (std::uint32_t id : old) {
    if (id == kNone) continue;
    std::size_t i = hash_all(tuple(id), arity_) & m;
    while (table_[i] != kNone) i = (i + 1) & m;
    table_[i] = id;
  }
}

std::uint32_t Relation::find(const Value* t) const {
  std::size_t m = table_.size() - 1;
  for (std::size_t i = hash_all(t, arity_) & m;; i = (i + 1) & m) {
    std::uint32_t id = table_[i];
    if (id == kNone) return kNone;
    const Value* u = tuple(id);
    unsigned c = 0;
    while (c < arity_ && u[c] == t[c]) ++c;
    if (c == arity_) return id;
  }
}

bool Relation::insert(const Value* t) {
  std::size_t m = table_.size() - 1;
  std::size_t i = hash_all(t, arity_) & m;
  for (;; i = (i + 1) & m) {
    std::uint32_t id = table_[i];
    if (id == kNone) break;
    const Value* u = tuple(id);
    unsigned c = 0;
    while (c < arity_ && u[c] == t[c]) ++c;
    if (c == arity_) return false;
  }
  table_[i] = static_cast<std::uint32_t>(count_);
  data_.insert(data_.end(), t, t + arity_);
  ++count_;
  if (count_ * 2 > table_.size()) grow();
  return true;
}

Index& Relation::index(std::uint32_t column_mask) {
  for (auto& idx : indexes_) {
    if (idx->column_mask() == column_mask) {
      idx->sync();
      return *idx;
    }
  }
  indexes_.push_back(std::make_unique<Index>(*this, column_mask));
  indexes_.back()->sync();
  return *indexes_.back();
}

void Relation::sync_indexes() {
  for (auto& idx : indexes_) idx->sync();
}

}  // namespace datalog
