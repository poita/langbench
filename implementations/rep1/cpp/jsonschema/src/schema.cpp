#include "jsonschema/schema.hpp"

#include "schema_internal.hpp"

namespace jsonschema {

Schema::Schema(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
Schema::Schema(Schema&&) noexcept = default;
Schema& Schema::operator=(Schema&&) noexcept = default;
Schema::~Schema() = default;

Schema Schema::compile(Value root, std::vector<Remote> remotes, std::string retrieval_uri) {
  auto impl = std::make_unique<Impl>();
  detail::compile_schema(impl->data, std::move(root), std::move(remotes), retrieval_uri);
  return Schema(std::move(impl));
}

Schema Schema::compile_json(std::string_view schema_json) { return compile(parse_json(schema_json)); }

bool Schema::is_valid(const Value& instance) const { return detail::evaluate(impl_->data, instance); }

}  // namespace jsonschema
