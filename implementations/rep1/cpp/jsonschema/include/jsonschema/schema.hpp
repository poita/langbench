// JSON Schema draft 2020-12 validation.
#pragma once

#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "jsonschema/json.hpp"

namespace jsonschema {

/// Thrown when a schema cannot be compiled (e.g. an invalid `pattern`) or when
/// validation reaches a reference that does not resolve.
class SchemaError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A schema document supplied alongside the root schema, addressed by an absolute URI.
using Remote = std::pair<std::string, Value>;

/// A compiled JSON Schema (draft 2020-12, validation vocabulary, `format` as annotation only).
///
/// Compilation walks the root schema and every remote once: it builds the
/// `$id` / `$anchor` / `$dynamicAnchor` index, decodes keywords, compiles
/// regular expressions and resolves references. After that, is_valid() only
/// evaluates. Numbers are compared exactly (see Decimal).
///
/// A Schema is immutable after construction, so is_valid() may be called
/// concurrently from several threads. Evaluation is recursive; very deeply
/// nested schemas or instances need a correspondingly large stack.
class Schema {
 public:
  /// Compiles `root`. `remotes` maps absolute URIs to further schema documents
  /// that `$ref`/`$dynamicRef` may point at; nothing is ever fetched. The root's
  /// retrieval URI is `retrieval_uri` (empty by default).
  /// Throws SchemaError.
  static Schema compile(Value root, std::vector<Remote> remotes = {}, std::string retrieval_uri = "");

  /// Convenience: parses `schema_json` and compiles it.
  static Schema compile_json(std::string_view schema_json);

  Schema(Schema&&) noexcept;
  Schema& operator=(Schema&&) noexcept;
  ~Schema();

  /// True if `instance` satisfies the schema. Throws SchemaError if evaluation
  /// reaches a reference that could not be resolved.
  bool is_valid(const Value& instance) const;

  struct Impl;  // implementation detail

 private:
  explicit Schema(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

}  // namespace jsonschema
