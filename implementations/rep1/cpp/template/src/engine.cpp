#include "jinjalite/engine.hpp"

#include "jinjalite/interpreter.hpp"
#include "jinjalite/json.hpp"
#include "jinjalite/parser.hpp"

namespace jinjalite {

/// A registered template: its source and, once loaded, its tree or the kind of
/// error loading produced (so a broken template is only analysed once).
struct Engine::Slot {
  std::string source;
  bool loaded = false;
  std::unique_ptr<Template> tree;
  bool failed = false;
  ErrorKind error_kind = ErrorKind::Syntax;
};

Engine::Engine() : context_(std::make_shared<Dict>()) {}
Engine::~Engine() = default;

void Engine::set_context(const Value& context) {
  if (!context.is_dict()) throw Error(ErrorKind::Type, "context must be a dict");
  context_ = context.dict_ptr();
}

void Engine::set_context_json(std::string_view json) {
  Value v = parse_json(json);
  if (!v.is_dict()) throw JsonError("context must be a JSON object");
  context_ = v.dict_ptr();
}

void Engine::add_template(std::string name, std::string source) {
  auto slot = std::make_unique<Slot>();
  slot->source = std::move(source);
  templates_[std::move(name)] = std::move(slot);
}

const Template& Engine::load(const std::string& name) {
  auto it = templates_.find(name);
  if (it == templates_.end()) throw Error(ErrorKind::Template, "no such template: " + name);
  Slot& slot = *it->second;
  if (!slot.loaded) {
    slot.loaded = true;
    try {
      slot.tree = parse_template(name, slot.source);
    } catch (const Error& e) {
      slot.failed = true;
      slot.error_kind = e.kind();
    }
  }
  if (slot.failed) throw Error(slot.error_kind, "cannot load template: " + name);
  return *slot.tree;
}

std::string Engine::render(const std::string& name) {
  const Template& main = load(name);
  Interpreter interp(context_, [this](const std::string& n) -> const Template& { return load(n); });
  return interp.render(main);
}

}  // namespace jinjalite
