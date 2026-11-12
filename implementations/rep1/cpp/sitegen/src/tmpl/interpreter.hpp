// Tree-walking renderer for parsed templates. Internal.
#pragma once

#include <memory>
#include <string>

#include "ast.hpp"
#include "parser.hpp"

namespace sitegen::tmpl {

/// Gives the interpreter access to other templates by name.
class TemplateLoader {
 public:
  virtual ~TemplateLoader() = default;
  /// Returns the parsed template; a stable pointer for the loader's lifetime.
  /// @throws TemplateError (Template if missing, Syntax/Filter if invalid).
  virtual const Template* load(const std::string& name) = 0;
};

class Interpreter {
 public:
  Interpreter(TemplateLoader& loader, SymbolTable& symbols);
  ~Interpreter();

  /// Renders `main` with the members of `context` as root variables.
  std::string render(const Template& main, const Dict& context);

  struct Impl;

 private:
  std::unique_ptr<Impl> impl_;
};

}  // namespace sitegen::tmpl
