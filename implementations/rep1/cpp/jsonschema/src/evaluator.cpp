// Schema evaluator: applies compiled Nodes to instances, tracking the dynamic
// scope and (when an `unevaluated*` keyword needs them) annotations.

#include <algorithm>
#include <numeric>

#include "jsonschema/utf8.hpp"
#include "schema_internal.hpp"

namespace jsonschema::detail {

namespace {

/// Evaluated items / properties of one (schema object, instance) pair.
/// Flags are indexed by array index or by object member position.
struct Annotations {
  std::vector<char> items;
  std::vector<char> props;

  static void mark(std::vector<char>& v, std::size_t i, std::size_t n) {
    if (v.size() < n) v.resize(n, 0);
    v[i] = 1;
  }
  void mark_item(std::size_t i, std::size_t n) { mark(items, i, n); }
  void mark_prop(std::size_t i, std::size_t n) { mark(props, i, n); }
  bool item(std::size_t i) const { return i < items.size() && items[i]; }
  bool prop(std::size_t i) const { return i < props.size() && props[i]; }

  void merge(const Annotations& o) {
    merge_into(items, o.items);
    merge_into(props, o.props);
  }

 private:
  static void merge_into(std::vector<char>& dst, const std::vector<char>& src) {
    if (src.empty()) return;
    if (dst.size() < src.size()) dst.resize(src.size(), 0);
    for (std::size_t i = 0; i < src.size(); ++i) dst[i] |= src[i];
  }
};

class Evaluator {
 public:
  explicit Evaluator(const SchemaData& d) : d_(d) {}

  bool run(const Value& instance) { return eval(d_.root, instance, nullptr); }

 private:
  // Returns whether `n` accepts `inst`. When `out` is non-null and the schema
  // accepts, the annotations it produces are merged into *out.
  bool eval(const Node* n, const Value& inst, Annotations* out) {
    if (n->kind == Node::Kind::True) return true;
    if (n->kind == Node::Kind::False) return false;

    const bool pushed = scope_.empty() || scope_.back() != n->base;
    if (pushed) scope_.push_back(n->base);
    bool ok = eval_object(*n, inst, out);
    if (pushed) scope_.pop_back();
    return ok;
  }

  bool eval_object(const Node& n, const Value& inst, Annotations* out) {
    Annotations local;
    Annotations* loc = (out || n.needs_local_annotations()) ? &local : nullptr;

    if (!check_any_type(n, inst)) return false;
    switch (inst.type()) {
      case Value::Type::Number:
        if (!check_number(n, inst.as_number())) return false;
        break;
      case Value::Type::String:
        if (!check_string(n, inst.as_string())) return false;
        break;
      case Value::Type::Array:
        if (!check_array(n, inst, loc)) return false;
        break;
      case Value::Type::Object:
        if (!check_object(n, inst, loc)) return false;
        break;
      default: break;
    }
    if (!check_applicators(n, inst, loc)) return false;

    if (n.unevaluated_items && inst.is_array()) {
      const std::size_t len = inst.size();
      for (std::size_t i = 0; i < len; ++i) {
        if (local.item(i)) continue;
        if (!eval(n.unevaluated_items, inst.items()[i], nullptr)) return false;
        local.mark_item(i, len);
      }
    }
    if (n.unevaluated_properties && inst.is_object()) {
      const std::size_t len = inst.size();
      for (std::size_t i = 0; i < len; ++i) {
        if (local.prop(i)) continue;
        if (!eval(n.unevaluated_properties, inst.items()[i], nullptr)) return false;
        local.mark_prop(i, len);
      }
    }
    if (out) out->merge(local);
    return true;
  }

  // ------------------------------------------------------------ any type

  static bool check_any_type(const Node& n, const Value& inst) {
    if (n.type_mask) {
      std::uint8_t bit = 0;
      switch (inst.type()) {
        case Value::Type::Null: bit = kNull; break;
        case Value::Type::Bool: bit = kBoolean; break;
        case Value::Type::Object: bit = kObject; break;
        case Value::Type::Array: bit = kArray; break;
        case Value::Type::String: bit = kString; break;
        case Value::Type::Number:
          bit = kNumber;
          if (inst.as_number().is_integer()) bit |= kInteger;
          break;
      }
      if (!(n.type_mask & bit)) return false;
    }
    if (n.enum_values) {
      bool found = false;
      for (const Value& e : n.enum_values->items()) {
        if (json_equal(e, inst)) {
          found = true;
          break;
        }
      }
      if (!found) return false;
    }
    if (n.const_value && !json_equal(*n.const_value, inst)) return false;
    return true;
  }

  // ------------------------------------------------------------ numbers

  static bool check_number(const Node& n, const Decimal& d) {
    if (n.multiple_of && !d.is_multiple_of(*n.multiple_of)) return false;
    if (n.maximum && d.compare(*n.maximum) > 0) return false;
    if (n.minimum && d.compare(*n.minimum) < 0) return false;
    if (n.exclusive_maximum && d.compare(*n.exclusive_maximum) >= 0) return false;
    if (n.exclusive_minimum && d.compare(*n.exclusive_minimum) <= 0) return false;
    return true;
  }

  // ------------------------------------------------------------ strings

  static bool check_string(const Node& n, const std::string& s) {
    if (n.max_length || n.min_length) {
      const std::uint64_t len = utf8::length(s);
      if (n.max_length && len > *n.max_length) return false;
      if (n.min_length && len < *n.min_length) return false;
    }
    if (n.pattern && !n.pattern->search(s)) return false;
    return true;
  }

  // ------------------------------------------------------------ arrays

  bool check_array(const Node& n, const Value& inst, Annotations* loc) {
    const std::size_t len = inst.size();
    if (n.max_items && len > *n.max_items) return false;
    if (n.min_items && len < *n.min_items) return false;
    if (n.unique_items && !items_unique(inst.items())) return false;

    std::size_t start = 0;
    if (n.has_prefix_items) {
      const std::size_t k = std::min(len, n.prefix_items.size());
      for (std::size_t i = 0; i < k; ++i) {
        if (!eval(n.prefix_items[i], inst.items()[i], nullptr)) return false;
        if (loc) loc->mark_item(i, len);
      }
      start = n.prefix_items.size();
    }
    if (n.items) {
      for (std::size_t i = start; i < len; ++i) {
        if (!eval(n.items, inst.items()[i], nullptr)) return false;
        if (loc) loc->mark_item(i, len);
      }
    }
    if (n.contains) {
      const std::uint64_t min = n.min_contains ? *n.min_contains : 1;
      std::uint64_t hits = 0;
      for (std::size_t i = 0; i < len; ++i) {
        if (eval(n.contains, inst.items()[i], nullptr)) {
          ++hits;
          if (loc) loc->mark_item(i, len);
          if (!loc && !n.max_contains && hits >= min) break;
        }
      }
      if (hits < min) return false;
      if (n.max_contains && hits > *n.max_contains) return false;
    }
    return true;
  }

  static bool items_unique(const std::vector<Value>& items) {
    const std::size_t n = items.size();
    if (n < 2) return true;
    if (n <= 8) {
      for (std::size_t i = 0; i < n; ++i) {
        for (std::size_t j = i + 1; j < n; ++j) {
          if (json_equal(items[i], items[j])) return false;
        }
      }
      return true;
    }
    std::vector<std::pair<std::size_t, std::size_t>> hashed(n);
    for (std::size_t i = 0; i < n; ++i) hashed[i] = {json_hash(items[i]), i};
    std::sort(hashed.begin(), hashed.end());
    for (std::size_t i = 0; i < n;) {
      std::size_t j = i + 1;
      while (j < n && hashed[j].first == hashed[i].first) ++j;
      for (std::size_t a = i; a < j; ++a) {
        for (std::size_t b = a + 1; b < j; ++b) {
          if (json_equal(items[hashed[a].second], items[hashed[b].second])) return false;
        }
      }
      i = j;
    }
    return true;
  }

  // ------------------------------------------------------------ objects

  bool check_object(const Node& n, const Value& inst, Annotations* loc) {
    const std::size_t len = inst.size();
    if (n.max_properties && len > *n.max_properties) return false;
    if (n.min_properties && len < *n.min_properties) return false;
    for (const std::string& r : n.required) {
      if (!inst.find(r)) return false;
    }
    for (const auto& [name, needed] : n.dependent_required) {
      if (!inst.find(name)) continue;
      for (const std::string& r : needed) {
        if (!inst.find(r)) return false;
      }
    }

    const bool per_member = !n.properties.empty() || !n.pattern_properties.empty() || n.additional_properties;
    if (per_member) {
      for (std::size_t i = 0; i < len; ++i) {
        const std::string& key = inst.keys()[i];
        const Value& val = inst.items()[i];
        bool matched = false;
        if (!n.properties.empty()) {
          auto it = n.properties.find(key);
          if (it != n.properties.end()) {
            matched = true;
            if (!eval(it->second, val, nullptr)) return false;
          }
        }
        for (const auto& [re, child] : n.pattern_properties) {
          if (re->search(key)) {
            matched = true;
            if (!eval(child, val, nullptr)) return false;
          }
        }
        if (!matched && n.additional_properties) {
          matched = true;
          if (!eval(n.additional_properties, val, nullptr)) return false;
        }
        if (matched && loc) loc->mark_prop(i, len);
      }
    }
    if (n.property_names) {
      for (const std::string& key : inst.keys()) {
        if (!eval(n.property_names, Value::string(key), nullptr)) return false;
      }
    }
    return true;
  }

  // ------------------------------------------------------------ applicators

  bool check_applicators(const Node& n, const Value& inst, Annotations* loc) {
    if (n.has_ref) {
      if (!n.ref_target) throw SchemaError(n.ref_error);
      if (!eval(n.ref_target, inst, loc)) return false;
    }
    if (n.has_dynamic_ref) {
      const Node* target = dynamic_target(n);
      if (!eval(target, inst, loc)) return false;
    }
    for (const Node* c : n.all_of) {
      if (!eval(c, inst, loc)) return false;
    }
    if (!n.any_of.empty()) {
      bool any = false;
      for (const Node* c : n.any_of) {
        if (eval(c, inst, loc)) {
          any = true;
          if (!loc) break;
        }
      }
      if (!any) return false;
    }
    if (!n.one_of.empty()) {
      int accepted = 0;
      for (const Node* c : n.one_of) {
        if (eval(c, inst, loc) && ++accepted > 1) return false;
      }
      if (accepted != 1) return false;
    }
    if (n.not_ && eval(n.not_, inst, nullptr)) return false;
    if (n.if_) {
      if (eval(n.if_, inst, loc)) {
        if (n.then_ && !eval(n.then_, inst, loc)) return false;
      } else if (n.else_ && !eval(n.else_, inst, loc)) {
        return false;
      }
    }
    if (n.dependent_schemas.empty()) return true;
    for (const auto& [name, child] : n.dependent_schemas) {
      if (inst.is_object() && inst.find(name) && !eval(child, inst, loc)) return false;
    }
    return true;
  }

  const Node* dynamic_target(const Node& n) const {
    if (!n.dynamic_target) throw SchemaError(n.dynamic_error);
    if (!n.dynamic_name.empty()) {
      const auto& by_base = d_.dynamic_anchors.at(n.dynamic_name);
      for (const std::string* base : scope_) {
        auto it = by_base.find(base);
        if (it != by_base.end()) return it->second;
      }
    }
    return n.dynamic_target;
  }

  const SchemaData& d_;
  std::vector<const std::string*> scope_;
};

}  // namespace

bool evaluate(const SchemaData& data, const Value& instance) { return Evaluator(data).run(instance); }

}  // namespace jsonschema::detail
