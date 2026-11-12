#include <memory>
#include <unordered_map>

#include "interpreter.hpp"
#include "parser.hpp"
#include "sitegen/template.hpp"

namespace sitegen {

const char* to_string(TemplateErrorKind kind) {
  switch (kind) {
    case TemplateErrorKind::Syntax: return "syntax";
    case TemplateErrorKind::Filter: return "filter";
    case TemplateErrorKind::Undefined: return "undefined";
    case TemplateErrorKind::Template: return "template";
    case TemplateErrorKind::Type: return "type";
  }
  return "unknown";
}

struct TemplateEngine::Impl : tmpl::TemplateLoader {
  struct Entry {
    std::string source;
    std::unique_ptr<tmpl::Template> parsed;
  };

  Impl() : interpreter(*this, symbols) {}

  const tmpl::Template* load(const std::string& name) override {
    const auto it = templates.find(name);
    if (it == templates.end()) {
      throw TemplateError(TemplateErrorKind::Template, "no such template: " + name);
    }
    Entry& entry = it->second;
    if (!entry.parsed) entry.parsed = tmpl::parse_template(entry.source, symbols);
    return entry.parsed.get();
  }

  std::unordered_map<std::string, Entry> templates;
  mutable tmpl::SymbolTable symbols;
  tmpl::Interpreter interpreter;
};

TemplateEngine::TemplateEngine() : impl_(std::make_unique<Impl>()) {}
TemplateEngine::~TemplateEngine() = default;
TemplateEngine::TemplateEngine(TemplateEngine&&) noexcept = default;
TemplateEngine& TemplateEngine::operator=(TemplateEngine&&) noexcept = default;

void TemplateEngine::add_template(std::string name, std::string source) {
  Impl::Entry entry;
  entry.source = std::move(source);
  impl_->templates[std::move(name)] = std::move(entry);
}

bool TemplateEngine::has_template(std::string_view name) const {
  return impl_->templates.count(std::string(name)) != 0;
}

std::string TemplateEngine::render(std::string_view name, const Dict& context) const {
  const tmpl::Template* main = impl_->load(std::string(name));
  return impl_->interpreter.render(*main, context);
}

}  // namespace sitegen
