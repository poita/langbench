#include "toml/value.hpp"

#include <cstdlib>

namespace toml {

namespace {
constexpr struct {
  Type type;
  std::string_view name;
} kTypeNames[] = {
    {Type::String, "string"},           {Type::Integer, "integer"},
    {Type::Float, "float"},             {Type::Bool, "bool"},
    {Type::DateTime, "datetime"},       {Type::DateTimeLocal, "datetime-local"},
    {Type::DateLocal, "date-local"},    {Type::TimeLocal, "time-local"},
};
}  // namespace

std::string_view type_name(Type type) {
  for (const auto& e : kTypeNames)
    if (e.type == type) return e.name;
  return "string";
}

bool type_from_name(std::string_view name, Type& out) {
  for (const auto& e : kTypeNames) {
    if (e.name == name) {
      out = e.type;
      return true;
    }
  }
  return false;
}

Value Value::scalar(Type type, std::string text) {
  Value v;
  v.data_ = Scalar{type, std::move(text)};
  v.origin_ = Origin::Literal;
  return v;
}

Value Value::integer(std::int64_t n) { return scalar(Type::Integer, std::to_string(n)); }

Value Value::array(Array items, Origin origin) {
  Value v;
  v.data_ = std::move(items);
  v.origin_ = origin;
  return v;
}

Value Value::table(Table members, Origin origin) {
  Value v;
  v.data_ = std::move(members);
  v.origin_ = origin;
  return v;
}

Value::Kind Value::kind() const { return static_cast<Kind>(data_.index()); }

Type Value::type() const {
  if (const auto* s = std::get_if<Scalar>(&data_)) return s->type;
  throw TypeError("value is not a scalar");
}

const std::string& Value::text() const {
  if (const auto* s = std::get_if<Scalar>(&data_)) return s->text;
  throw TypeError("value is not a scalar");
}

const std::string& Value::as_string() const {
  if (type() != Type::String) throw TypeError("value is not a string");
  return text();
}

std::int64_t Value::as_integer() const {
  if (type() != Type::Integer) throw TypeError("value is not an integer");
  return std::strtoll(text().c_str(), nullptr, 10);
}

double Value::as_float() const {
  if (type() != Type::Float) throw TypeError("value is not a float");
  return std::strtod(text().c_str(), nullptr);
}

bool Value::as_bool() const {
  if (type() != Type::Bool) throw TypeError("value is not a bool");
  return text() == "true";
}

const Value::Array& Value::items() const {
  if (const auto* a = std::get_if<Array>(&data_)) return *a;
  throw TypeError("value is not an array");
}

Value::Array& Value::items() {
  if (auto* a = std::get_if<Array>(&data_)) return *a;
  throw TypeError("value is not an array");
}

const Value::Table& Value::members() const {
  if (const auto* t = std::get_if<Table>(&data_)) return *t;
  throw TypeError("value is not a table");
}

Value::Table& Value::members() {
  if (auto* t = std::get_if<Table>(&data_)) return *t;
  throw TypeError("value is not a table");
}

const Value* Value::find(std::string_view key) const {
  const auto* t = std::get_if<Table>(&data_);
  if (!t) return nullptr;
  auto it = t->find(key);
  return it == t->end() ? nullptr : &it->second;
}

}  // namespace toml
