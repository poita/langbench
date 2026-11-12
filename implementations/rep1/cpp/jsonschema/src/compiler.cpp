// Schema compiler: indexes every document (ids, anchors), decodes keywords into
// Nodes, compiles patterns and resolves references.

#include <unordered_map>

#include "jsonschema/uri.hpp"
#include "jsonschema/utf8.hpp"
#include "schema_internal.hpp"

namespace jsonschema::detail {

namespace {

class Compiler {
 public:
  explicit Compiler(SchemaData& data) : d_(data) {}

  Node* compile_document(const Value& doc, const std::string& retrieval) {
    const std::string* base = d_.intern(retrieval);
    Node* node = compile(doc, base);
    if (!node) throw SchemaError("schema document '" + retrieval + "' is neither an object nor a boolean");
    d_.resources.emplace(retrieval, node);
    return node;
  }

  /// Resolves every pending `$ref` / `$dynamicRef`. Failures are recorded on the
  /// node and only reported if evaluation reaches it.
  void link() {
    for (std::size_t i = 0; i < pending_.size(); ++i) {
      Node* n = pending_[i];
      if (n->has_ref) {
        try {
          n->ref_target = resolve_reference(n->ref, *n->base);
        } catch (const SchemaError& e) {
          n->ref_error = e.what();
        }
      }
      if (n->has_dynamic_ref) {
        try {
          n->dynamic_target = resolve_reference(n->dynamic_ref, *n->base);
          n->dynamic_name = dynamic_name_of(n->dynamic_ref, *n->base);
        } catch (const SchemaError& e) {
          n->dynamic_error = e.what();
        }
      }
    }
  }

 private:
  static std::string anchor_key(const std::string& base, const std::string& name) { return base + "#" + name; }

  Node* new_node() {
    d_.nodes.emplace_back();
    return &d_.nodes.back();
  }

  // Compiles a subschema if `v` is a boolean or an object; otherwise returns nullptr.
  Node* compile(const Value& v, const std::string* base) {
    if (v.is_bool()) {
      Node* n = new_node();
      n->kind = v.as_bool() ? Node::Kind::True : Node::Kind::False;
      n->value = &v;
      n->base = base;
      d_.by_value[&v] = n;
      return n;
    }
    if (!v.is_object()) return nullptr;

    Node* n = new_node();
    n->value = &v;
    if (const Value* id = v.find("$id"); id && id->is_string()) {
      base = d_.intern(uri::resolve(uri::strip_fragment(id->as_string()), *base));
      d_.resources.emplace(*base, n);
    }
    n->base = base;
    d_.by_value[&v] = n;

    if (const Value* a = v.find("$anchor"); a && a->is_string()) {
      std::string key = anchor_key(*base, a->as_string());
      if (plain_anchors_.insert(key).second) d_.anchors[key] = n;  // an $anchor displaces a $dynamicAnchor
    }
    if (const Value* a = v.find("$dynamicAnchor"); a && a->is_string()) {
      d_.dynamic_anchors[a->as_string()].emplace(base, n);
      d_.anchors.emplace(anchor_key(*base, a->as_string()), n);  // does not displace an $anchor
    }

    decode_keywords(*n, v, base);
    return n;
  }

  const Node* sub(const Value* v, const std::string* base) { return v ? compile(*v, base) : nullptr; }

  // An array of schemas; empty result with `ok == false` if the value is not one.
  bool schema_array(const Value* v, const std::string* base, std::vector<const Node*>& out) {
    if (!v || !v->is_array()) return false;
    std::vector<const Node*> tmp;
    for (const Value& e : v->items()) {
      const Node* c = compile(e, base);
      if (!c) return false;
      tmp.push_back(c);
    }
    out = std::move(tmp);
    return true;
  }

  static Node::Count count_of(const Value* v) {
    if (!v || !v->is_number()) return std::nullopt;
    return v->as_number().to_count();
  }

  static std::optional<Decimal> number_of(const Value* v) {
    if (!v || !v->is_number()) return std::nullopt;
    return v->as_number();
  }

  Node::RegexPtr compile_pattern(const std::string& p) {
    auto it = regex_cache_.find(p);
    if (it != regex_cache_.end()) return it->second;
    Node::RegexPtr r;
    try {
      r = std::make_shared<const Regex>(Regex::compile(p));
    } catch (const RegexError& e) {
      throw SchemaError("pattern '" + p + "': " + e.what());
    }
    regex_cache_.emplace(p, r);
    return r;
  }

  static std::vector<std::string> string_array(const Value* v) {
    std::vector<std::string> out;
    if (v && v->is_array()) {
      for (const Value& e : v->items()) {
        if (e.is_string()) out.push_back(e.as_string());
      }
    }
    return out;
  }

  void decode_keywords(Node& n, const Value& v, const std::string* base) {
    // --- any type
    if (const Value* t = v.find("type")) {
      auto bit = [](const std::string& s) -> std::uint8_t {
        if (s == "null") return kNull;
        if (s == "boolean") return kBoolean;
        if (s == "object") return kObject;
        if (s == "array") return kArray;
        if (s == "number") return kNumber;
        if (s == "string") return kString;
        if (s == "integer") return kInteger;
        return 0;
      };
      std::uint8_t mask = 0;
      bool valid = true;
      if (t->is_string()) {
        mask = bit(t->as_string());
      } else if (t->is_array()) {
        for (const Value& e : t->items()) {
          if (e.is_string()) mask |= bit(e.as_string());
        }
      } else {
        valid = false;
      }
      if (valid) {
        n.type_mask = mask ? mask : 0x80;  // 0x80: a `type` that nothing satisfies
      }
    }
    if (const Value* e = v.find("enum"); e && e->is_array()) n.enum_values = e;
    n.const_value = v.find("const");

    // --- numbers
    n.multiple_of = number_of(v.find("multipleOf"));
    if (n.multiple_of && (n.multiple_of->is_zero() || n.multiple_of->is_negative())) n.multiple_of.reset();
    n.maximum = number_of(v.find("maximum"));
    n.minimum = number_of(v.find("minimum"));
    n.exclusive_maximum = number_of(v.find("exclusiveMaximum"));
    n.exclusive_minimum = number_of(v.find("exclusiveMinimum"));

    // --- strings
    n.max_length = count_of(v.find("maxLength"));
    n.min_length = count_of(v.find("minLength"));
    if (const Value* p = v.find("pattern"); p && p->is_string()) n.pattern = compile_pattern(p->as_string());

    // --- arrays
    n.max_items = count_of(v.find("maxItems"));
    n.min_items = count_of(v.find("minItems"));
    if (const Value* u = v.find("uniqueItems"); u && u->is_bool()) n.unique_items = u->as_bool();
    n.has_prefix_items = schema_array(v.find("prefixItems"), base, n.prefix_items);
    n.items = sub(v.find("items"), base);
    n.contains = sub(v.find("contains"), base);
    n.min_contains = count_of(v.find("minContains"));
    n.max_contains = count_of(v.find("maxContains"));

    // --- objects
    n.max_properties = count_of(v.find("maxProperties"));
    n.min_properties = count_of(v.find("minProperties"));
    n.required = string_array(v.find("required"));
    if (const Value* dr = v.find("dependentRequired"); dr && dr->is_object()) {
      for (std::size_t i = 0; i < dr->size(); ++i) {
        if (dr->items()[i].is_array()) n.dependent_required.emplace_back(dr->keys()[i], string_array(&dr->items()[i]));
      }
    }
    if (const Value* p = v.find("properties"); p && p->is_object()) {
      for (std::size_t i = 0; i < p->size(); ++i) {
        if (const Node* c = compile(p->items()[i], base)) n.properties.emplace(p->keys()[i], c);
      }
    }
    if (const Value* p = v.find("patternProperties"); p && p->is_object()) {
      for (std::size_t i = 0; i < p->size(); ++i) {
        if (const Node* c = compile(p->items()[i], base)) {
          n.pattern_properties.emplace_back(compile_pattern(p->keys()[i]), c);
        }
      }
    }
    n.additional_properties = sub(v.find("additionalProperties"), base);
    n.property_names = sub(v.find("propertyNames"), base);
    if (const Value* p = v.find("dependentSchemas"); p && p->is_object()) {
      for (std::size_t i = 0; i < p->size(); ++i) {
        if (const Node* c = compile(p->items()[i], base)) n.dependent_schemas.emplace_back(p->keys()[i], c);
      }
    }

    // --- in-place applicators
    schema_array(v.find("allOf"), base, n.all_of);
    schema_array(v.find("anyOf"), base, n.any_of);
    schema_array(v.find("oneOf"), base, n.one_of);
    n.not_ = sub(v.find("not"), base);
    n.if_ = sub(v.find("if"), base);
    n.then_ = sub(v.find("then"), base);
    n.else_ = sub(v.find("else"), base);
    n.unevaluated_items = sub(v.find("unevaluatedItems"), base);
    n.unevaluated_properties = sub(v.find("unevaluatedProperties"), base);

    // --- indexed but never applied
    if (const Value* defs = v.find("$defs"); defs && defs->is_object()) {
      for (const Value& e : defs->items()) compile(e, base);
    }
    sub(v.find("contentSchema"), base);

    // --- references
    if (const Value* r = v.find("$ref"); r && r->is_string()) {
      n.has_ref = true;
      n.ref = r->as_string();
      pending_.push_back(&n);
    }
    if (const Value* r = v.find("$dynamicRef"); r && r->is_string()) {
      n.has_dynamic_ref = true;
      n.dynamic_ref = r->as_string();
      if (!n.has_ref) pending_.push_back(&n);
    }
  }

  // The plain-name fragment of `ref` when it names a dynamic anchor under the resolved document.
  std::string dynamic_name_of(const std::string& ref, const std::string& base) {
    auto [doc, frag] = uri::split_fragment(uri::resolve(ref, base));
    if (!frag || frag->empty()) return "";
    std::string name = uri::percent_decode(*frag);
    if (name.empty() || name[0] == '/') return "";
    auto it = d_.dynamic_anchors.find(name);
    if (it == d_.dynamic_anchors.end()) return "";
    const std::string* doc_base = d_.intern(doc);
    return it->second.count(doc_base) ? name : "";
  }

  const Node* resolve_reference(const std::string& ref, const std::string& base) {
    const std::string full = uri::resolve(ref, base);
    auto [doc, frag_raw] = uri::split_fragment(full);
    const std::string frag = frag_raw ? uri::percent_decode(*frag_raw) : std::string();
    auto res = d_.resources.find(doc);
    if (frag.empty()) {
      if (res == d_.resources.end()) throw SchemaError("unresolved reference '" + full + "'");
      return res->second;
    }
    if (frag[0] == '/') {
      if (res == d_.resources.end()) throw SchemaError("unresolved reference '" + full + "'");
      return follow_pointer(*res->second, frag, full);
    }
    auto it = d_.anchors.find(anchor_key(doc, frag));
    if (it == d_.anchors.end()) throw SchemaError("unresolved reference '" + full + "'");
    return it->second;
  }

  const Node* follow_pointer(const Node& resource, const std::string& pointer, const std::string& full) {
    auto tokens = uri::parse_json_pointer(pointer);
    if (!tokens) throw SchemaError("invalid JSON pointer in '" + full + "'");
    const Value* cur = resource.value;
    const std::string* base = resource.base;
    for (std::size_t i = 0; i < tokens->size(); ++i) {
      const std::string& tok = (*tokens)[i];
      const Value* next = nullptr;
      if (cur->is_object()) {
        next = cur->find(tok);
      } else if (cur->is_array() && !tok.empty() && tok.find_first_not_of("0123456789") == std::string::npos &&
                 tok.size() < 10) {
        std::size_t idx = std::stoul(tok);
        if (idx < cur->size()) next = &cur->items()[idx];
      }
      if (!next) throw SchemaError("JSON pointer does not resolve in '" + full + "'");
      cur = next;
      if (i + 1 < tokens->size() && cur->is_object()) {
        if (const Value* id = cur->find("$id"); id && id->is_string()) {
          base = d_.intern(uri::resolve(uri::strip_fragment(id->as_string()), *base));
        }
      }
    }
    auto it = d_.by_value.find(cur);
    if (it != d_.by_value.end()) return it->second;
    // The pointer lands on a position the indexing walk did not visit; compile it on demand.
    const Node* n = compile(*cur, base);
    if (!n) throw SchemaError("reference '" + full + "' does not point at a schema");
    return n;
  }

  SchemaData& d_;
  std::vector<Node*> pending_;
  std::unordered_set<std::string> plain_anchors_;
  std::unordered_map<std::string, Node::RegexPtr> regex_cache_;
};

}  // namespace

void compile_schema(SchemaData& data, Value root, std::vector<Remote> remotes, const std::string& retrieval_uri) {
  Compiler compiler(data);
  data.documents.push_back(std::make_unique<Value>(std::move(root)));
  data.root = compiler.compile_document(*data.documents.back(), retrieval_uri);
  for (Remote& r : remotes) {
    data.documents.push_back(std::make_unique<Value>(std::move(r.second)));
    // A remote that is neither an object nor a boolean is simply unusable.
    const Value& doc = *data.documents.back();
    if (doc.is_object() || doc.is_bool()) compiler.compile_document(doc, r.first);
  }
  compiler.link();
}

}  // namespace jsonschema::detail
