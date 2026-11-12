// Internal data structures shared by the schema compiler and the evaluator.
#pragma once

#include <cstdint>
#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "jsonschema/decimal.hpp"
#include "jsonschema/json.hpp"
#include "jsonschema/regex.hpp"
#include "jsonschema/schema.hpp"

namespace jsonschema::detail {

enum TypeBit : std::uint8_t {
  kNull = 1,
  kBoolean = 2,
  kObject = 4,
  kArray = 8,
  kNumber = 16,
  kString = 32,
  kInteger = 64,
};

/// A compiled schema object (or boolean schema) with its keywords decoded.
/// Pointers to other nodes and to JSON values stay valid for the life of the Schema.
struct Node {
  enum class Kind { Object, True, False };
  using Count = std::optional<std::uint64_t>;
  using RegexPtr = std::shared_ptr<const Regex>;

  Kind kind = Kind::Object;
  const Value* value = nullptr;
  const std::string* base = nullptr;  // interned base URI in force at this node

  // any type
  std::uint8_t type_mask = 0;  // 0 = no `type` keyword
  const Value* enum_values = nullptr;
  const Value* const_value = nullptr;

  // numbers
  std::optional<Decimal> multiple_of, maximum, minimum, exclusive_maximum, exclusive_minimum;

  // strings
  Count max_length, min_length;
  RegexPtr pattern;

  // arrays
  Count max_items, min_items;
  bool unique_items = false;
  std::vector<const Node*> prefix_items;
  bool has_prefix_items = false;
  const Node* items = nullptr;
  const Node* contains = nullptr;
  Count min_contains, max_contains;

  // objects
  Count max_properties, min_properties;
  std::vector<std::string> required;
  std::vector<std::pair<std::string, std::vector<std::string>>> dependent_required;
  std::unordered_map<std::string, const Node*> properties;
  std::vector<std::pair<RegexPtr, const Node*>> pattern_properties;
  const Node* additional_properties = nullptr;
  const Node* property_names = nullptr;
  std::vector<std::pair<std::string, const Node*>> dependent_schemas;

  // in-place applicators
  std::vector<const Node*> all_of, any_of, one_of;
  const Node* not_ = nullptr;
  const Node* if_ = nullptr;
  const Node* then_ = nullptr;
  const Node* else_ = nullptr;
  const Node* unevaluated_items = nullptr;
  const Node* unevaluated_properties = nullptr;

  // references
  bool has_ref = false;
  std::string ref;                    // the raw `$ref` value
  const Node* ref_target = nullptr;   // resolved at link time
  std::string ref_error;              // set when resolution failed
  bool has_dynamic_ref = false;
  std::string dynamic_ref;
  const Node* dynamic_target = nullptr;  // static target (as if it were `$ref`)
  std::string dynamic_name;              // non-empty when the reference is dynamic
  std::string dynamic_error;

  bool needs_local_annotations() const { return unevaluated_items || unevaluated_properties; }
};

/// Everything a compiled schema owns.
struct SchemaData {
  std::vector<std::unique_ptr<Value>> documents;
  std::deque<Node> nodes;
  std::unordered_set<std::string> interned;
  std::unordered_map<std::string, Node*> resources;  // base URI -> schema resource root
  std::unordered_map<std::string, Node*> anchors;    // base '#' name -> node ($anchor, then $dynamicAnchor)
  std::unordered_map<std::string, std::unordered_map<const std::string*, Node*>> dynamic_anchors;  // name -> base -> node
  std::unordered_map<const Value*, Node*> by_value;
  const Node* root = nullptr;

  const std::string* intern(const std::string& s) { return &*interned.insert(s).first; }
};

}  // namespace jsonschema::detail

struct jsonschema::Schema::Impl {
  detail::SchemaData data;
};

namespace jsonschema::detail {

/// Builds the index, decodes keywords and resolves references. Throws SchemaError.
void compile_schema(SchemaData& data, Value root, std::vector<Remote> remotes, const std::string& retrieval_uri);

/// Evaluates the schema against an instance. Throws SchemaError on unresolved references.
bool evaluate(const SchemaData& data, const Value& instance);

}  // namespace jsonschema::detail
