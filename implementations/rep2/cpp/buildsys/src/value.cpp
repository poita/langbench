#include "kiln/value.hpp"

#include <functional>

namespace kiln {

const char* typeName(Type t) noexcept {
  switch (t) {
    case Type::Bool: return "bool";
    case Type::Int: return "int";
    case Type::Str: return "str";
    case Type::List: return "list";
  }
  return "?";
}

unsigned maskOf(Type t) noexcept {
  switch (t) {
    case Type::Bool: return kBool;
    case Type::Int: return kInt;
    case Type::Str: return kStr;
    case Type::List: return kList;
  }
  return 0;
}

std::string maskName(unsigned mask) {
  std::string s;
  auto add = [&](const char* n) {
    if (!s.empty()) s += '|';
    s += n;
  };
  if (mask & kStr) add("str");
  if (mask & kInt) add("int");
  if (mask & kBool) add("bool");
  if (mask & kList) add("list");
  return s;
}

Value Value::boolean(bool b) noexcept {
  Value v;
  v.type_ = Type::Bool;
  v.i_ = b ? 1 : 0;
  return v;
}

Value Value::integer(std::int64_t i) noexcept {
  Value v;
  v.type_ = Type::Int;
  v.i_ = i;
  return v;
}

Value Value::string(std::string s) {
  Value v;
  v.type_ = Type::Str;
  v.p_ = std::make_shared<const std::string>(std::move(s));
  return v;
}

Value Value::list(List items) {
  Value v;
  v.type_ = Type::List;
  v.p_ = std::make_shared<const List>(std::move(items));
  return v;
}

int compare(const Value& a, const Value& b) {
  if (a.type() != b.type()) return static_cast<int>(a.type()) < static_cast<int>(b.type()) ? -1 : 1;
  switch (a.type()) {
    case Type::Bool:
    case Type::Int: {
      std::int64_t x = a.asInt(), y = b.asInt();
      return x < y ? -1 : (x > y ? 1 : 0);
    }
    case Type::Str: {
      int c = a.asStr().compare(b.asStr());
      return c < 0 ? -1 : (c > 0 ? 1 : 0);
    }
    case Type::List: {
      const auto& x = a.asList();
      const auto& y = b.asList();
      std::size_t n = x.size() < y.size() ? x.size() : y.size();
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

std::size_t hashValue(const Value& v) {
  switch (v.type()) {
    case Type::Bool: return v.asBool() ? 0x9e37 : 0x7f4a;
    case Type::Int: return std::hash<std::int64_t>()(v.asInt()) ^ 0x1234567;
    case Type::Str: return std::hash<std::string>()(v.asStr());
    case Type::List: {
      std::size_t h = 0xabcdef + v.asList().size();
      for (const auto& e : v.asList()) h = h * 1000003u ^ hashValue(e);
      return h;
    }
  }
  return 0;
}

std::string toText(const Value& v) {
  switch (v.type()) {
    case Type::Bool: return v.asBool() ? "true" : "false";
    case Type::Int: return std::to_string(v.asInt());
    case Type::Str: return v.asStr();
    case Type::List: break;
  }
  return {};
}

}  // namespace kiln
