#include "jq/filter.hpp"

#include "interpreter.hpp"
#include "jq/json.hpp"
#include "parser.hpp"

namespace jq {

struct Filter::Impl {
  detail::Program program;
};

Filter Filter::compile(std::string_view source) {
  auto impl = std::make_shared<Impl>();
  impl->program = detail::parse_program(source);
  Filter f;
  f.impl_ = std::move(impl);
  return f;
}

void Filter::run(const Value& input, const Callback& emit) const {
  if (!impl_) throw Error("filter is not compiled");
  detail::evaluate(*impl_->program.root, input, [&](const Value& v) { emit(v); });
}

std::vector<Value> Filter::collect(const Value& input) const {
  std::vector<Value> out;
  run(input, [&](const Value& v) { out.push_back(v); });
  return out;
}

std::vector<std::string> evaluate(std::string_view filter, std::string_view json) {
  Filter f = Filter::compile(filter);
  Value input = parse_json(json);
  std::vector<std::string> out;
  f.run(input, [&](const Value& v) { out.push_back(to_json(v)); });
  return out;
}

}  // namespace jq
