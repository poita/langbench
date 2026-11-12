/// \file reader.hpp
/// Recursive-descent reader: text to datums.
#pragma once

#include <optional>
#include <string_view>

#include "scheme/value.hpp"

namespace scheme {

/// Reads successive datums from a source text. Symbols are interned in the
/// given table. The text must outlive the reader.
class Reader {
 public:
  Reader(std::string_view source, SymbolTable& symbols) : src_(source), symbols_(symbols) {}

  /// The next datum, or std::nullopt at end of input.
  /// Throws SchemeError(SyntaxError) on malformed input.
  std::optional<Value> read();

 private:
  Value read_datum();
  Value read_list();
  Value read_string();
  Value read_atom();
  void skip_space();
  bool at_end() const { return pos_ >= src_.size(); }
  static bool is_delimiter(char c);

  std::string_view src_;
  size_t pos_ = 0;
  SymbolTable& symbols_;
};

}  // namespace scheme
