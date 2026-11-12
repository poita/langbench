/// @file template.hpp
/// A Jinja-style template engine: `{{ expr }}`, `{% if/for/set/macro/include/
/// extends/block %}`, comments, whitespace control and thirteen filters.
///
/// Typical use:
/// @code
///   sitegen::TemplateEngine engine;
///   engine.add_template("base.html", "<h1>{% block title %}{% endblock %}</h1>");
///   engine.add_template("page.html",
///       "{% extends \"base.html\" %}{% block title %}{{ name|upper }}{% endblock %}");
///   sitegen::Dict context;
///   context.set("name", sitegen::Value::string("hello"));
///   std::string html = engine.render("page.html", context);  // "<h1>HELLO</h1>"
/// @endcode
///
/// Semantics follow Jinja2 with strict undefined handling, no automatic
/// escaping and no automatic whitespace trimming (see README for the full
/// language reference).
#pragma once

#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

#include "sitegen/value.hpp"

namespace sitegen {

/// Categories of template failures.
enum class TemplateErrorKind {
  Syntax,     ///< template cannot be lexed or parsed
  Filter,     ///< unknown filter name in a loaded template
  Undefined,  ///< forbidden use of an undefined value
  Template,   ///< `include`/`extends` of a template that does not exist
  Type,       ///< operand or argument of the wrong kind
};

/// Name of an error kind: "syntax", "filter", "undefined", "template", "type".
const char* to_string(TemplateErrorKind kind);

/// Thrown when loading or rendering a template fails.
class TemplateError : public std::runtime_error {
 public:
  TemplateError(TemplateErrorKind kind, const std::string& message)
      : std::runtime_error(message), kind_(kind) {}
  TemplateErrorKind kind() const { return kind_; }

 private:
  TemplateErrorKind kind_;
};

/// A collection of named templates that can be rendered.
///
/// Each template is lexed, parsed and checked at most once, the first time a
/// rendering needs it; templates that are never needed are never parsed. The
/// engine is not thread-safe (rendering updates its internal cache).
class TemplateEngine {
 public:
  TemplateEngine();
  ~TemplateEngine();
  TemplateEngine(TemplateEngine&&) noexcept;
  TemplateEngine& operator=(TemplateEngine&&) noexcept;
  TemplateEngine(const TemplateEngine&) = delete;
  TemplateEngine& operator=(const TemplateEngine&) = delete;

  /// Registers (or replaces) a template. `source` is used verbatim: callers
  /// that want Jinja's "one trailing newline is dropped" behaviour must
  /// remove it themselves.
  void add_template(std::string name, std::string source);

  bool has_template(std::string_view name) const;

  /// Renders the named template with the members of `context` as the root
  /// variables. Rendering is all-or-nothing.
  /// @throws TemplateError on any failure, including a missing `name`.
  std::string render(std::string_view name, const Dict& context) const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace sitegen
