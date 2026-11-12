/// @file toml.hpp
/// Reader for the small TOML subset used by `site.toml` and content front
/// matter: `key = value` lines with string, integer, boolean and
/// array-of-strings values, blank lines and `#` comments.
#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace sitegen::toml {

/// Thrown for input that is not in the supported subset.
class ParseError : public std::runtime_error {
 public:
  ParseError(const std::string& message, std::size_t line)
      : std::runtime_error("line " + std::to_string(line) + ": " + message), line_(line) {}
  /// 1-based line number of the offending line within the parsed text.
  std::size_t line() const { return line_; }

 private:
  std::size_t line_;
};

/// A parsed value.
class Value {
 public:
  enum class Type { String, Integer, Boolean, Array };

  static Value string(std::string s);
  static Value integer(std::int64_t i);
  static Value boolean(bool b);
  static Value array(std::vector<std::string> items);

  Type type() const { return type_; }
  bool is_string() const { return type_ == Type::String; }
  bool is_integer() const { return type_ == Type::Integer; }
  bool is_boolean() const { return type_ == Type::Boolean; }
  bool is_array() const { return type_ == Type::Array; }

  /// Accessors; the value must have the matching type.
  const std::string& as_string() const { return string_; }
  std::int64_t as_integer() const { return integer_; }
  bool as_boolean() const { return boolean_; }
  const std::vector<std::string>& as_array() const { return array_; }

 private:
  Type type_ = Type::String;
  std::string string_;
  std::int64_t integer_ = 0;
  bool boolean_ = false;
  std::vector<std::string> array_;
};

struct Entry {
  std::string key;
  Value value;
};

/// An ordered list of `key = value` entries.
class Document {
 public:
  const std::vector<Entry>& entries() const { return entries_; }
  void add(std::string key, Value value);

  /// The value for `key`, or nullptr.
  const Value* find(std::string_view key) const;

  /// Typed lookups returning `fallback` when the key is absent or has another
  /// type.
  std::string get_string(std::string_view key, std::string fallback = {}) const;
  std::int64_t get_integer(std::string_view key, std::int64_t fallback = 0) const;
  bool get_boolean(std::string_view key, bool fallback = false) const;
  std::vector<std::string> get_array(std::string_view key) const;

 private:
  std::vector<Entry> entries_;
};

/// Parses a whole document (lines separated by LF).
/// @throws ParseError if a line is not blank, a comment or an assignment.
Document parse(std::string_view text);

/// A content file split into its front matter and Markdown body.
struct FrontMatter {
  Document meta;
  std::string body;
};

/// Splits `+++\n<toml>+++\n<body>`: the front matter ends at the first later
/// line that is exactly `+++`; the body is everything after that line's LF.
/// @throws ParseError if the file has no front matter or the TOML is invalid.
FrontMatter split_front_matter(std::string_view file);

}  // namespace sitegen::toml
