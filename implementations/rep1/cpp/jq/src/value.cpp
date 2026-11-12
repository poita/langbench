#include "jq/value.hpp"

#include <algorithm>
#include <cstring>
#include <functional>

namespace jq {

const char* type_name(Type t) noexcept {
  switch (t) {
    case Type::Null: return "null";
    case Type::False:
    case Type::True: return "boolean";
    case Type::Number: return "number";
    case Type::String: return "string";
    case Type::Array: return "array";
    case Type::Object: return "object";
  }
  return "?";
}

Value Value::string(std::string s) {
  Value v;
  v.type_ = Type::String;
  v.ptr_ = std::make_shared<const std::string>(std::move(s));
  return v;
}

Value Value::array(Array items) {
  Value v;
  v.type_ = Type::Array;
  v.ptr_ = std::make_shared<const Array>(std::move(items));
  return v;
}

Value Value::object(Object obj) {
  Value v;
  v.type_ = Type::Object;
  v.ptr_ = std::make_shared<const Object>(std::move(obj));
  return v;
}

// ---------------------------------------------------------------- Object

long Object::index_of(std::string_view key) const {
  if (entries_.size() <= kLinearLimit) {
    for (std::size_t i = 0; i < entries_.size(); ++i)
      if (entries_[i].key == key) return static_cast<long>(i);
    return -1;
  }
  if (table_.empty()) rebuild_table();
  const std::size_t mask = table_.size() - 1;
  std::size_t h = std::hash<std::string_view>{}(key) & mask;
  while (true) {
    std::uint32_t e = table_[h];
    if (e == kEmpty) return -1;
    if (entries_[e].key == key) return static_cast<long>(e);
    h = (h + 1) & mask;
  }
}

void Object::table_insert(std::uint32_t i) const {
  const std::size_t mask = table_.size() - 1;
  std::size_t h = std::hash<std::string_view>{}(entries_[i].key) & mask;
  while (table_[h] != kEmpty) h = (h + 1) & mask;
  table_[h] = i;
}

void Object::rebuild_table() const {
  std::size_t cap = 16;
  while (cap < entries_.size() * 2) cap <<= 1;
  table_.assign(cap, kEmpty);
  for (std::size_t i = 0; i < entries_.size(); ++i) table_insert(static_cast<std::uint32_t>(i));
}

const Value* Object::find(std::string_view key) const {
  long i = index_of(key);
  return i < 0 ? nullptr : &entries_[static_cast<std::size_t>(i)].value;
}

const std::vector<std::uint32_t>& Object::sorted_order() const {
  if (!sorted_ready_) {
    sorted_.resize(entries_.size());
    for (std::size_t i = 0; i < sorted_.size(); ++i) sorted_[i] = static_cast<std::uint32_t>(i);
    std::sort(sorted_.begin(), sorted_.end(), [this](std::uint32_t a, std::uint32_t b) {
      return entries_[a].key < entries_[b].key;
    });
    sorted_ready_ = true;
  }
  return sorted_;
}

std::vector<std::string> Object::sorted_keys() const {
  std::vector<std::string> keys;
  keys.reserve(entries_.size());
  for (std::uint32_t i : sorted_order()) keys.push_back(entries_[i].key);
  return keys;
}

ObjectBuilder::ObjectBuilder(const Object& base) {
  obj_.entries_ = base.entries_;
  obj_.table_ = base.table_;
  obj_.sorted_ = base.sorted_;
  obj_.sorted_ready_ = base.sorted_ready_;
}

void ObjectBuilder::set(std::string_view key, Value value) {
  long i = obj_.index_of(key);
  if (i >= 0) {
    obj_.entries_[static_cast<std::size_t>(i)].value = std::move(value);
    return;
  }
  obj_.entries_.push_back({std::string(key), std::move(value)});
  obj_.sorted_ready_ = false;
  if (!obj_.table_.empty()) {
    if (obj_.entries_.size() * 2 > obj_.table_.size())
      obj_.rebuild_table();
    else
      obj_.table_insert(static_cast<std::uint32_t>(obj_.entries_.size() - 1));
  }
}

Object ObjectBuilder::build() {
  Object out = std::move(obj_);
  obj_ = Object();
  return out;
}

// --------------------------------------------------------------- compare

namespace {

int cmp_strings(const std::string& a, const std::string& b) {
  // std::string compares as unsigned bytes, i.e. in code point order for UTF-8.
  int c = a.compare(b);
  return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

int compare_arrays(const Value::Array& a, const Value::Array& b) {
  const std::size_t n = std::min(a.size(), b.size());
  for (std::size_t i = 0; i < n; ++i) {
    int c = compare(a[i], b[i]);
    if (c != 0) return c;
  }
  if (a.size() == b.size()) return 0;
  return a.size() < b.size() ? -1 : 1;
}

int compare_objects(const Object& a, const Object& b) {
  const auto& sa = a.sorted_order();
  const auto& sb = b.sorted_order();
  const std::size_t n = std::min(sa.size(), sb.size());
  for (std::size_t i = 0; i < n; ++i) {
    int c = cmp_strings(a.entry(sa[i]).key, b.entry(sb[i]).key);
    if (c != 0) return c;
  }
  if (sa.size() != sb.size()) return sa.size() < sb.size() ? -1 : 1;
  for (std::size_t i = 0; i < n; ++i) {
    int c = compare(a.entry(sa[i]).value, b.entry(sb[i]).value);
    if (c != 0) return c;
  }
  return 0;
}

}  // namespace

int compare(const Value& a, const Value& b) {
  if (a.type() != b.type()) return a.type() < b.type() ? -1 : 1;
  switch (a.type()) {
    case Type::Null:
    case Type::False:
    case Type::True: return 0;
    case Type::Number:
      return a.number() < b.number() ? -1 : (a.number() > b.number() ? 1 : 0);
    case Type::String: return cmp_strings(a.string(), b.string());
    case Type::Array: return compare_arrays(a.array(), b.array());
    case Type::Object: return compare_objects(a.object(), b.object());
  }
  return 0;
}

}  // namespace jq
