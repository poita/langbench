// A small JSON document model with exact numbers, plus a parser.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "jsonschema/decimal.hpp"

namespace jsonschema {

/// Thrown by parse_json() on malformed input.
class JsonParseError : public std::runtime_error {
 public:
  JsonParseError(const std::string& message, std::size_t offset)
      : std::runtime_error(message + " at offset " + std::to_string(offset)), offset_(offset) {}
  std::size_t offset() const noexcept { return offset_; }

 private:
  std::size_t offset_;
};

/// A JSON value. Numbers are exact decimals (see Decimal); object members keep
/// their document order and are looked up through a hash index once an object
/// has more than a handful of members.
class Value {
 public:
  enum class Type { Null, Bool, Number, String, Array, Object };

  /// A null value.
  Value() = default;

  static Value boolean(bool b);
  static Value number(Decimal d);
  static Value string(std::string s);
  static Value array(std::vector<Value> items = {});
  static Value object();

  Type type() const noexcept { return type_; }
  bool is_null() const noexcept { return type_ == Type::Null; }
  bool is_bool() const noexcept { return type_ == Type::Bool; }
  bool is_number() const noexcept { return type_ == Type::Number; }
  bool is_string() const noexcept { return type_ == Type::String; }
  bool is_array() const noexcept { return type_ == Type::Array; }
  bool is_object() const noexcept { return type_ == Type::Object; }

  bool as_bool() const noexcept { return bool_; }
  const Decimal& as_number() const noexcept { return number_; }
  const std::string& as_string() const noexcept { return string_; }

  /// Number of elements (array) or members (object); 0 for other types.
  std::size_t size() const noexcept { return items_.size(); }
  /// Array elements, or member values of an object (parallel to keys()).
  const std::vector<Value>& items() const noexcept { return items_; }
  /// Member names of an object, in document order.
  const std::vector<std::string>& keys() const noexcept { return keys_; }

  /// The member called `key`, or nullptr. Expected O(1) for large objects.
  const Value* find(std::string_view key) const;

  /// Appends an element to an array.
  void push_back(Value v);
  /// Appends a member to an object. If the key already exists, find() keeps returning the first.
  void add_member(std::string key, Value v);

  /// Serialises to compact JSON (numbers in canonical form).
  std::string dump() const;

 private:
  using Index = std::unordered_map<std::string, std::uint32_t>;
  static constexpr std::size_t kIndexThreshold = 8;

  Type type_ = Type::Null;
  bool bool_ = false;
  Decimal number_;
  std::string string_;
  std::vector<Value> items_;
  std::vector<std::string> keys_;
  std::shared_ptr<Index> index_;
};

/// Parses exactly one JSON value (RFC 8259) from UTF-8 text.
Value parse_json(std::string_view text);

/// JSON equality (JSON Schema section "equality"): numbers compare by value,
/// objects ignore member order, different types are never equal.
bool json_equal(const Value& a, const Value& b);

/// A hash consistent with json_equal.
std::size_t json_hash(const Value& v);

}  // namespace jsonschema
