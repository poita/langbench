#include "jinjalite/scope.hpp"

namespace jinjalite {

void Scope::set(std::string_view name, Value value) {
  if (index_.empty()) {
    for (auto& v : vars_) {
      if (v.first == name) {
        v.second = std::move(value);
        return;
      }
    }
  } else if (auto it = index_.find(name); it != index_.end()) {
    vars_[it->second].second = std::move(value);
    return;
  }
  vars_.emplace_back(std::string(name), std::move(value));
  if (!index_.empty()) {
    index_.emplace(vars_.back().first, vars_.size() - 1);
  } else if (vars_.size() > kLinearLimit) {
    for (size_t i = 0; i < vars_.size(); ++i) index_.emplace(vars_[i].first, i);
  }
}

const Value* Scope::find(std::string_view name) const {
  for (const Scope* s = this; s; s = s->parent_.get()) {
    if (s->context_) {
      if (const Value* v = s->context_->find(name)) return v;
      continue;
    }
    if (s->index_.empty()) {
      for (const auto& v : s->vars_) {
        if (v.first == name) return &v.second;
      }
    } else if (auto it = s->index_.find(name); it != s->index_.end()) {
      return &s->vars_[it->second].second;
    }
  }
  return nullptr;
}

}  // namespace jinjalite
