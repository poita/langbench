#include "jinjalite/value.hpp"

namespace jinjalite {

void Dict::set(std::string key, Value value) {
  if (index_.empty()) {
    for (auto& e : entries_) {
      if (e.first == key) {
        e.second = std::move(value);
        return;
      }
    }
  } else if (auto it = index_.find(key); it != index_.end()) {
    entries_[it->second].second = std::move(value);
    return;
  }
  entries_.emplace_back(std::move(key), std::move(value));
  if (!index_.empty()) {
    index_.emplace(entries_.back().first, entries_.size() - 1);
  } else if (entries_.size() > kLinearLimit) {
    for (size_t i = 0; i < entries_.size(); ++i) index_.emplace(entries_[i].first, i);
  }
}

const Value* Dict::find(std::string_view key) const {
  if (index_.empty()) {
    for (const auto& e : entries_) {
      if (e.first == key) return &e.second;
    }
    return nullptr;
  }
  auto it = index_.find(key);
  return it == index_.end() ? nullptr : &entries_[it->second].second;
}

}  // namespace jinjalite
