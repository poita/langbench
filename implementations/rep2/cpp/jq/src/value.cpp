#include "jq/value.hpp"

#include <algorithm>
#include <cstring>

namespace jq {

namespace {

struct StringData final : detail::Heap {
  explicit StringData(std::string s) : str(std::move(s)) {}
  std::string str;
};

struct ArrayData final : detail::Heap {
  explicit ArrayData(std::vector<Value> v) : items(std::move(v)) {}
  std::vector<Value> items;
};

}  // namespace

Value Value::string(std::string s) { return Value(Type::String, new StringData(std::move(s))); }
Value Value::array(std::vector<Value> items) {
  return Value(Type::Array, new ArrayData(std::move(items)));
}
Value Value::object(std::vector<Member> members) {
  return Value(Type::Object, new Object(std::move(members)));
}

const std::string& Value::as_string() const noexcept {
  return static_cast<const StringData*>(heap_)->str;
}
const std::vector<Value>& Value::as_array() const noexcept {
  return static_cast<const ArrayData*>(heap_)->items;
}
const Object& Value::as_object() const noexcept { return *static_cast<const Object*>(heap_); }

const char* Value::type_name() const noexcept {
  switch (type_) {
    case Type::Null: return "null";
    case Type::False:
    case Type::True: return "boolean";
    case Type::Number: return "number";
    case Type::String: return "string";
    case Type::Array: return "array";
    case Type::Object: return "object";
  }
  return "null";
}

const Value* Object::find(std::string_view key) const {
  constexpr std::size_t kLinearLimit = 12;
  if (members_.size() <= kLinearLimit) {
    for (const Member& m : members_)
      if (m.key == key) return &m.value;
    return nullptr;
  }
  if (!indexed_) {
    index_.reserve(members_.size() * 2);
    for (std::uint32_t i = 0; i < members_.size(); ++i) index_.emplace(members_[i].key, i);
    indexed_ = true;
  }
  auto it = index_.find(key);
  return it == index_.end() ? nullptr : &members_[it->second].value;
}

const std::vector<std::uint32_t>& Object::sorted_order() const {
  if (!sorted_valid_) {
    sorted_.resize(members_.size());
    for (std::uint32_t i = 0; i < sorted_.size(); ++i) sorted_[i] = i;
    std::sort(sorted_.begin(), sorted_.end(), [this](std::uint32_t a, std::uint32_t b) {
      return members_[a].key < members_[b].key;  // byte order == code point order
    });
    sorted_valid_ = true;
  }
  return sorted_;
}

ObjectBuilder::ObjectBuilder(const Object& base) : members_(base.members()) {}

void ObjectBuilder::build_index() {
  index_.reserve(members_.size() * 2);
  for (std::uint32_t i = 0; i < members_.size(); ++i) index_.emplace(members_[i].key, i);
  indexed_ = true;
}

Member* ObjectBuilder::lookup(std::string_view key) {
  if (members_.size() <= kIndexThreshold) {
    for (Member& m : members_)
      if (m.key == key) return &m;
    return nullptr;
  }
  if (!indexed_) build_index();
  auto it = index_.find(std::string(key));
  return it == index_.end() ? nullptr : &members_[it->second];
}

void ObjectBuilder::set(std::string key, Value value) {
  if (Member* m = lookup(key)) {
    m->value = std::move(value);
    return;
  }
  if (indexed_) index_.emplace(key, static_cast<std::uint32_t>(members_.size()));
  members_.push_back(Member{std::move(key), std::move(value)});
}

Value ObjectBuilder::build() {
  Value v = Value::object(std::move(members_));
  members_.clear();
  index_.clear();
  indexed_ = false;
  return v;
}

namespace {

int compare_strings(const std::string& a, const std::string& b) {
  std::size_t n = std::min(a.size(), b.size());
  int c = n ? std::memcmp(a.data(), b.data(), n) : 0;
  if (c != 0) return c < 0 ? -1 : 1;
  return a.size() < b.size() ? -1 : (a.size() > b.size() ? 1 : 0);
}

}  // namespace

int compare(const Value& a, const Value& b) {
  if (a.type() != b.type()) return a.type() < b.type() ? -1 : 1;
  switch (a.type()) {
    case Type::Number: {
      double x = a.as_number(), y = b.as_number();
      return x < y ? -1 : (x > y ? 1 : 0);
    }
    case Type::String: return compare_strings(a.as_string(), b.as_string());
    case Type::Array: {
      const auto& x = a.as_array();
      const auto& y = b.as_array();
      std::size_t n = std::min(x.size(), y.size());
      for (std::size_t i = 0; i < n; ++i)
        if (int c = compare(x[i], y[i])) return c;
      return x.size() < y.size() ? -1 : (x.size() > y.size() ? 1 : 0);
    }
    case Type::Object: {
      const Object& x = a.as_object();
      const Object& y = b.as_object();
      const auto& xo = x.sorted_order();
      const auto& yo = y.sorted_order();
      std::size_t n = std::min(xo.size(), yo.size());
      for (std::size_t i = 0; i < n; ++i)
        if (int c = compare_strings(x.members()[xo[i]].key, y.members()[yo[i]].key)) return c;
      if (xo.size() != yo.size()) return xo.size() < yo.size() ? -1 : 1;
      for (std::size_t i = 0; i < n; ++i)
        if (int c = compare(x.members()[xo[i]].value, y.members()[yo[i]].value)) return c;
      return 0;
    }
    default: return 0;
  }
}

}  // namespace jq
