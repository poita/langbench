// KBL values: str, int, bool, list. Copies are O(1); values are immutable.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace kiln {

/// Declaration order is the cross-type order of the total order.
enum class Type { Bool, Int, Str, List };

/// `bool`, `int`, `str` or `list`.
std::string_view type_name(Type t) noexcept;

class Value {
 public:
  using List = std::vector<Value>;

  Value() : type_(Type::Bool) {}

  static Value boolean(bool b);
  static Value integer(std::int64_t i);
  static Value string(std::string s);
  static Value list(List items);

  Type type() const noexcept { return type_; }
  bool is(Type t) const noexcept { return type_ == t; }

  bool as_bool() const noexcept { return int_ != 0; }
  std::int64_t as_int() const noexcept { return int_; }
  const std::string& as_str() const noexcept { return *str_; }
  const List& as_list() const noexcept { return *list_; }

 private:
  Type type_;
  std::int64_t int_ = 0;
  std::shared_ptr<const std::string> str_;
  std::shared_ptr<const List> list_;
};

/// Three-way comparison under the KBL total order (-1, 0, 1).
int compare(const Value& a, const Value& b);

/// Deep structural equality.
bool equal(const Value& a, const Value& b);

/// Strict-weak "less" under the total order, for use with ordered containers.
struct ValueLess {
  bool operator()(const Value& a, const Value& b) const { return compare(a, b) < 0; }
};

}  // namespace kiln
