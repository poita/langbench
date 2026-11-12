#include "kiln/value.hpp"

#include <algorithm>

namespace kiln {

std::string_view type_name(Type t) noexcept {
  switch (t) {
    case Type::Bool: return "bool";
    case Type::Int: return "int";
    case Type::Str: return "str";
    case Type::List: return "list";
  }
  return "?";
}

Value Value::boolean(bool b) {
  Value v;
  v.type_ = Type::Bool;
  v.int_ = b ? 1 : 0;
  return v;
}

Value Value::integer(std::int64_t i) {
  Value v;
  v.type_ = Type::Int;
  v.int_ = i;
  return v;
}

Value Value::string(std::string s) {
  Value v;
  v.type_ = Type::Str;
  v.str_ = std::make_shared<const std::string>(std::move(s));
  return v;
}

Value Value::list(List items) {
  Value v;
  v.type_ = Type::List;
  v.list_ = std::make_shared<const List>(std::move(items));
  return v;
}

int compare(const Value& a, const Value& b) {
  if (a.type() != b.type()) return a.type() < b.type() ? -1 : 1;
  switch (a.type()) {
    case Type::Bool:
    case Type::Int:
      return a.as_int() < b.as_int() ? -1 : (a.as_int() > b.as_int() ? 1 : 0);
    case Type::Str: {
      int c = a.as_str().compare(b.as_str());
      return c < 0 ? -1 : (c > 0 ? 1 : 0);
    }
    case Type::List: {
      const auto& x = a.as_list();
      const auto& y = b.as_list();
      std::size_t n = std::min(x.size(), y.size());
      for (std::size_t i = 0; i < n; ++i) {
        int c = compare(x[i], y[i]);
        if (c != 0) return c;
      }
      return x.size() < y.size() ? -1 : (x.size() > y.size() ? 1 : 0);
    }
  }
  return 0;
}

bool equal(const Value& a, const Value& b) { return compare(a, b) == 0; }

}  // namespace kiln
