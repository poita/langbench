#pragma once
/// \file engine.hpp
/// The public entry point of the library: an `Engine` holds a JSON context
/// and a set of named templates and renders one of them.

#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "jinjalite/ast.hpp"
#include "jinjalite/error.hpp"
#include "jinjalite/value.hpp"

namespace jinjalite {

/// A template engine instance.
///
/// Templates are parsed lazily, at most once each, the first time they are
/// needed (the rendered template, or one named by `include`/`extends`).
/// Errors are reported by throwing `jinjalite::Error`; rendering is
/// all-or-nothing, so no partial output escapes.
class Engine {
 public:
  Engine();
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  /// Sets the root variables. `context` must be a dict value.
  void set_context(const Value& context);
  /// Sets the root variables from a JSON object document (member order is
  /// preserved). Throws `JsonError` if malformed or not an object.
  void set_context_json(std::string_view json);

  /// Registers (or replaces) a template's source.
  void add_template(std::string name, std::string source);

  /// Renders the template `name` and returns its text.
  /// Throws `Error` (kind `Template` if `name` is unknown).
  std::string render(const std::string& name);

 private:
  struct Slot;
  const Template& load(const std::string& name);

  DictPtr context_;
  std::unordered_map<std::string, std::unique_ptr<Slot>> templates_;
};

/// A parsed stdin document: JSON context plus the named templates in order.
struct Document {
  Value context;
  std::vector<std::pair<std::string, std::string>> templates;
};

/// Splits the command-line tool's input format into context and templates.
/// Throws `std::runtime_error` (or `JsonError`) if the input is malformed.
Document parse_document(std::string_view input);

/// Parses `input` as a document and renders its first template.
/// Throws `Error` for template errors.
std::string render_document(std::string_view input);

/// Like `render_document` but never throws `Error`: returns the rendered text
/// followed by `\n`, or the single line `error: <kind>\n`.
std::string render_document_or_error_line(std::string_view input);

}  // namespace jinjalite
