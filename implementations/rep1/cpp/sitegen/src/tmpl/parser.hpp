// Lexer and parser for the template language. Internal.
#pragma once

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "ast.hpp"

namespace sitegen::tmpl {

/// Interns variable names to small integers so scopes can compare ids.
class SymbolTable {
 public:
  int intern(std::string_view name);
  const std::string& name(int id) const { return names_[static_cast<std::size_t>(id)]; }

 private:
  struct Hash {
    using is_transparent = void;
    std::size_t operator()(std::string_view s) const { return std::hash<std::string_view>()(s); }
  };
  std::unordered_map<std::string, int, Hash, std::equal_to<>> ids_;
  std::vector<std::string> names_;
};

/// Lexes, parses and filter-checks `source`.
/// @throws TemplateError (Syntax or Filter).
std::unique_ptr<Template> parse_template(std::string_view source, SymbolTable& symbols);

}  // namespace sitegen::tmpl
