#pragma once
/// \file value.hpp
/// The document value model: null, bool, int, string, list and object, with
/// serialisation, canonical rendering, deep comparison and field-path access.

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace tessera {

/// A field path, one entry per segment (`a.b.c` is `{"a","b","c"}`).
using Path = std::vector<std::string>;

/// The path text: the segments joined by `.`.
std::string path_text(const Path& path);
/// Inverse of `path_text`.
Path split_path_text(std::string_view text);

/// A document value. Objects keep their fields sorted by name (byte-wise), so
/// the order fields were supplied in is not observable.
class Value {
 public:
  enum class Kind { Null = 0, Bool = 1, Int = 2, String = 3, List = 4, Object = 5 };
  using Field = std::pair<std::string, Value>;

  Value() = default;  ///< null

  static Value null() { return Value(); }
  static Value boolean(bool b);
  static Value integer(std::int64_t i);
  static Value string(std::string s);
  static Value list(std::vector<Value> items);
  /// Builds an object; sorts the fields. Throws `Error(DupField)` on a repeated name.
  static Value object(std::vector<Field> fields);

  Kind kind() const { return kind_; }
  /// Type rank used by comparisons and index keys (0 = null ... 5 = object).
  int rank() const { return static_cast<int>(kind_); }

  bool as_bool() const { return bool_; }
  std::int64_t as_int() const { return int_; }
  const std::string& as_string() const { return str_; }
  const std::vector<Value>& items() const { return items_; }
  /// Fields in ascending byte-wise name order.
  const std::vector<Field>& fields() const { return fields_; }

  /// The field called `name`, or nullptr.
  const Value* field(std::string_view name) const;
  Value* field(std::string_view name);
  /// Sets (inserting or replacing) a field of an object.
  void set_field(std::string_view name, Value v);
  /// Removes a field of an object; returns false if absent.
  bool erase_field(std::string_view name);

  /// Deep equality (same kind and same content).
  friend bool operator==(const Value& a, const Value& b);

 private:
  Kind kind_ = Kind::Null;
  bool bool_ = false;
  std::int64_t int_ = 0;
  std::string str_;
  std::vector<Value> items_;
  std::vector<Field> fields_;
};

/// Nesting depth: 1 for scalars, 1 + deepest child for containers.
int depth(const Value& v);

/// The stored form of a document (spec section 4.2).
std::string serialize(const Value& v);
/// Inverse of `serialize`. The input must be well formed.
Value deserialize(std::string_view bytes);

/// Canonical one-line rendering (spec section 4.4).
std::string render(const Value& v);
/// A string rendered with quotes and the escaping of spec section 4.5.
std::string render_string(std::string_view s);

/// Three-way comparison of two scalars of the same kind (null, bool, int, string).
int compare_scalars(const Value& a, const Value& b);

/// Resolves a path; returns nullptr if it is missing. Lists are never traversed.
const Value* resolve_path(const Value& doc, const Path& path);
/// Sets the value at `path`, creating empty objects for missing intermediate
/// segments. Throws `Error(NotObject)` when a traversed value is not an object.
void set_path(Value& doc, const Path& path, Value v);
/// Removes the field at `path`. Throws `Error(NotObject)` / `Error(NoField)`.
void unset_path(Value& doc, const Path& path);

}  // namespace tessera
