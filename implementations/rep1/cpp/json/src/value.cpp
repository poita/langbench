#include "jsoncanon/value.hpp"

#include <utility>

namespace jsoncanon {

Value::Value() noexcept : v_(nullptr) {}
Value::Value(std::nullptr_t) noexcept : v_(nullptr) {}
Value::Value(bool b) noexcept : v_(b) {}
Value::Value(Number n) : v_(std::move(n)) {}
Value::Value(std::string s) : v_(std::move(s)) {}
Value::Value(const char* s) : v_(std::string(s)) {}
Value::Value(Array a) : v_(std::move(a)) {}
Value::Value(Object o) : v_(std::move(o)) {}

Value::Value(const Value&) = default;
Value::Value(Value&&) noexcept = default;
Value& Value::operator=(const Value&) = default;
Value& Value::operator=(Value&&) noexcept = default;
Value::~Value() = default;

Value Value::number(std::string lexeme) { return Value(Number{std::move(lexeme)}); }

Type Value::type() const noexcept { return static_cast<Type>(v_.index()); }

bool Value::as_bool() const { return std::get<bool>(v_); }
const std::string& Value::as_number_text() const { return std::get<Number>(v_).text; }
const std::string& Value::as_string() const { return std::get<std::string>(v_); }
const Value::Array& Value::as_array() const { return std::get<Array>(v_); }
Value::Array& Value::as_array() { return std::get<Array>(v_); }
const Value::Object& Value::as_object() const { return std::get<Object>(v_); }
Value::Object& Value::as_object() { return std::get<Object>(v_); }

}  // namespace jsoncanon
