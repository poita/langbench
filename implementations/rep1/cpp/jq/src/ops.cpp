#include "ops.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <numeric>

#include "jq/error.hpp"
#include "jq/json.hpp"

namespace jq::detail {

namespace {

[[noreturn]] void type_error(const char* what, const Value& a, const Value& b) {
  throw RuntimeError(std::string(a.type_name()) + " and " + b.type_name() + " cannot be " + what);
}

Value split_string(const std::string& s, const std::string& sep) {
  Value::Array out;
  if (s.empty()) return Value::array(std::move(out));
  if (sep.empty()) {
    for (std::size_t i = 0; i < s.size();) {
      std::size_t n = 1;
      while (i + n < s.size() && (static_cast<unsigned char>(s[i + n]) & 0xC0) == 0x80) ++n;
      out.push_back(Value::string(s.substr(i, n)));
      i += n;
    }
    return Value::array(std::move(out));
  }
  std::size_t start = 0;
  while (true) {
    std::size_t at = s.find(sep, start);
    if (at == std::string::npos) {
      out.push_back(Value::string(s.substr(start)));
      break;
    }
    out.push_back(Value::string(s.substr(start, at - start)));
    start = at + sep.size();
  }
  return Value::array(std::move(out));
}

Value repeat_string(const std::string& s, double n) {
  if (n < 0 || std::isnan(n)) return Value::null();
  double t = std::trunc(n);
  if (t == 0 || s.empty()) return Value::string("");
  if (t * static_cast<double>(s.size()) > 1e9) throw RuntimeError("repeat string result too long");
  std::string out;
  std::size_t count = static_cast<std::size_t>(t);
  out.reserve(s.size() * count);
  for (std::size_t i = 0; i < count; ++i) out += s;
  return Value::string(std::move(out));
}

Value merge_objects(const Object& a, const Object& b, bool deep) {
  if (b.empty()) return Value::object(a);
  ObjectBuilder r(a);
  r.reserve(a.size() + b.size());
  for (const auto& e : b) {
    if (deep) {
      const Value* av = r.find(e.key);
      if (av && av->is_object() && e.value.is_object()) {
        r.set(e.key, merge_objects(av->object(), e.value.object(), true));
        continue;
      }
    }
    r.set(e.key, e.value);
  }
  return r.build_value();
}

Value subtract_arrays(const Value::Array& a, const Value::Array& b) {
  Value::Array out;
  if (b.size() <= 4) {
    for (const Value& x : a) {
      bool found = false;
      for (const Value& y : b)
        if (compare(x, y) == 0) { found = true; break; }
      if (!found) out.push_back(x);
    }
    return Value::array(std::move(out));
  }
  std::vector<const Value*> sorted;
  sorted.reserve(b.size());
  for (const Value& y : b) sorted.push_back(&y);
  std::sort(sorted.begin(), sorted.end(),
            [](const Value* p, const Value* q) { return compare(*p, *q) < 0; });
  for (const Value& x : a) {
    auto it = std::lower_bound(sorted.begin(), sorted.end(), &x,
                               [](const Value* p, const Value* q) { return compare(*p, *q) < 0; });
    if (it == sorted.end() || compare(**it, x) != 0) out.push_back(x);
  }
  return Value::array(std::move(out));
}

Value add_values(const Value& a, const Value& b) {
  if (a.is_null()) return b;
  if (b.is_null()) return a;
  if (a.type() == b.type()) {
    switch (a.type()) {
      case Type::Number: return Value::number(a.number() + b.number());
      case Type::String: return Value::string(a.string() + b.string());
      case Type::Array: {
        Value::Array out;
        out.reserve(a.array().size() + b.array().size());
        out.insert(out.end(), a.array().begin(), a.array().end());
        out.insert(out.end(), b.array().begin(), b.array().end());
        return Value::array(std::move(out));
      }
      case Type::Object: return merge_objects(a.object(), b.object(), false);
      default: break;
    }
  }
  type_error("added", a, b);
}

}  // namespace

Value binary_op(BinOp op, const Value& a, const Value& b) {
  switch (op) {
    case BinOp::Add: return add_values(a, b);
    case BinOp::Sub:
      if (a.is_number() && b.is_number()) return Value::number(a.number() - b.number());
      if (a.is_array() && b.is_array()) return subtract_arrays(a.array(), b.array());
      type_error("subtracted", a, b);
    case BinOp::Mul:
      if (a.is_number() && b.is_number()) return Value::number(a.number() * b.number());
      if (a.is_string() && b.is_number()) return repeat_string(a.string(), b.number());
      if (a.is_number() && b.is_string()) return repeat_string(b.string(), a.number());
      if (a.is_object() && b.is_object()) return merge_objects(a.object(), b.object(), true);
      type_error("multiplied", a, b);
    case BinOp::Div:
      if (a.is_number() && b.is_number()) {
        if (b.number() == 0) throw RuntimeError("number and number cannot be divided because the divisor is zero");
        return Value::number(a.number() / b.number());
      }
      if (a.is_string() && b.is_string()) return split_string(a.string(), b.string());
      type_error("divided", a, b);
    case BinOp::Mod:
      if (a.is_number() && b.is_number()) {
        double x = std::trunc(a.number()), y = std::trunc(b.number());
        if (y == 0) throw RuntimeError("number and number cannot be divided because the divisor is zero");
        double r = std::fmod(x, y);
        return Value::number(r == 0 ? 0.0 : r);
      }
      type_error("divided", a, b);
    case BinOp::Eq: return Value::boolean(compare(a, b) == 0);
    case BinOp::Ne: return Value::boolean(compare(a, b) != 0);
    case BinOp::Lt: return Value::boolean(compare(a, b) < 0);
    case BinOp::Le: return Value::boolean(compare(a, b) <= 0);
    case BinOp::Gt: return Value::boolean(compare(a, b) > 0);
    case BinOp::Ge: return Value::boolean(compare(a, b) >= 0);
  }
  return Value();
}

Value negate(const Value& v) {
  if (!v.is_number()) throw RuntimeError(std::string(v.type_name()) + " cannot be negated");
  return Value::number(-v.number());
}

const Value* index_value(const Value& t, const Value& k, std::string* err) {
  static const Value kNull;
  if (k.is_string()) {
    if (t.is_object()) {
      const Value* v = t.object().find(k.string());
      return v ? v : &kNull;
    }
    if (t.is_null()) return &kNull;
    if (err) *err = std::string("Cannot index ") + t.type_name() + " with \"" + k.string() + "\"";
    return nullptr;
  }
  if (k.is_number()) {
    if (t.is_array()) {
      const auto& arr = t.array();
      double d = std::trunc(k.number());
      double len = static_cast<double>(arr.size());
      if (d < 0) d += len;
      if (!(d >= 0 && d < len)) return &kNull;
      return &arr[static_cast<std::size_t>(d)];
    }
    if (t.is_null()) return &kNull;
    if (err) *err = std::string("Cannot index ") + t.type_name() + " with number";
    return nullptr;
  }
  if (err) *err = std::string("Cannot index ") + t.type_name() + " with " + k.type_name();
  return nullptr;
}

bool slice_value(const Value& t, const Value* from, const Value* to, Value& out,
                 std::string* err) {
  if (t.is_null()) {
    out = Value();
    return true;
  }
  if (!t.is_array() && !t.is_string()) {
    if (err) *err = std::string("Cannot index ") + t.type_name() + " with object";
    return false;
  }
  auto bad_bound = [](const Value* v) { return v && !v->is_null() && !v->is_number(); };
  if (bad_bound(from) || bad_bound(to)) {
    if (err) *err = "Start and end indices of an array slice must be numbers";
    return false;
  }
  // Length in code points (or elements).
  std::size_t len;
  bool ascii = true;
  if (t.is_array()) {
    len = t.array().size();
  } else {
    const std::string& s = t.string();
    len = 0;
    for (unsigned char c : s) {
      if ((c & 0xC0) != 0x80) ++len;
      if (c >= 0x80) ascii = false;
    }
  }
  const double dlen = static_cast<double>(len);
  double s = (from && from->is_number()) ? std::floor(from->number()) : 0;
  double e = (to && to->is_number()) ? std::ceil(to->number()) : dlen;
  if (s < 0) s += dlen;
  if (e < 0) e += dlen;
  s = std::min(std::max(s, 0.0), dlen);
  e = std::min(std::max(e, 0.0), dlen);
  if (e < s) e = s;
  const std::size_t si = static_cast<std::size_t>(s), ei = static_cast<std::size_t>(e);
  if (t.is_array()) {
    const auto& arr = t.array();
    out = Value::array(Value::Array(arr.begin() + static_cast<std::ptrdiff_t>(si),
                                    arr.begin() + static_cast<std::ptrdiff_t>(ei)));
    return true;
  }
  const std::string& str = t.string();
  if (ascii) {
    out = Value::string(str.substr(si, ei - si));
    return true;
  }
  // Map code point offsets to byte offsets.
  std::size_t byte = 0, cp = 0, bs = str.size(), be = str.size();
  for (; byte < str.size(); ++byte) {
    if ((static_cast<unsigned char>(str[byte]) & 0xC0) == 0x80) continue;
    if (cp == si) bs = byte;
    if (cp == ei) { be = byte; break; }
    ++cp;
  }
  if (si >= len) bs = str.size();
  if (be < bs) be = bs;
  out = Value::string(str.substr(bs, be - bs));
  return true;
}

// ---------------------------------------------------------------- builtins

Value builtin_length(const Value& v) {
  switch (v.type()) {
    case Type::Null: return Value::number(0);
    case Type::Number: return Value::number(std::fabs(v.number()));
    case Type::String: {
      double n = 0;
      for (unsigned char c : v.string())
        if ((c & 0xC0) != 0x80) ++n;
      return Value::number(n);
    }
    case Type::Array: return Value::number(static_cast<double>(v.array().size()));
    case Type::Object: return Value::number(static_cast<double>(v.object().size()));
    default: throw RuntimeError(std::string(v.type_name()) + " has no length");
  }
}

Value builtin_keys(const Value& v) {
  Value::Array out;
  if (v.is_object()) {
    const Object& o = v.object();
    out.reserve(o.size());
    for (std::uint32_t i : o.sorted_order()) out.push_back(Value::string(o.entry(i).key));
  } else if (v.is_array()) {
    out.reserve(v.array().size());
    for (std::size_t i = 0; i < v.array().size(); ++i) out.push_back(Value::number(static_cast<double>(i)));
  } else {
    throw RuntimeError(std::string(v.type_name()) + " has no keys");
  }
  return Value::array(std::move(out));
}

bool builtin_has(const Value& v, const Value& k) {
  if (v.is_null()) return false;
  if (v.is_object() && k.is_string()) return v.object().contains(k.string());
  if (v.is_array() && k.is_number()) {
    double d = std::trunc(k.number());
    return d >= 0 && d < static_cast<double>(v.array().size());
  }
  throw RuntimeError(std::string("Cannot check whether ") + v.type_name() + " has a " +
                     (k.is_string() ? "string" : k.type_name()) + " key");
}

Value builtin_add(const Value::Array& items) {
  // Linear-time fast paths when every non-null element has the same kind.
  const Value* first = nullptr;
  bool uniform = true;
  for (const Value& x : items) {
    if (x.is_null()) continue;
    if (!first) first = &x;
    else if (x.type() != first->type()) { uniform = false; break; }
  }
  if (!first) return Value();
  if (uniform) {
    switch (first->type()) {
      case Type::String: {
        std::string s;
        for (const Value& x : items) if (!x.is_null()) s += x.string();
        return Value::string(std::move(s));
      }
      case Type::Array: {
        Value::Array out;
        for (const Value& x : items) if (!x.is_null()) out.insert(out.end(), x.array().begin(), x.array().end());
        return Value::array(std::move(out));
      }
      case Type::Object: {
        ObjectBuilder b;
        for (const Value& x : items)
          if (!x.is_null())
            for (const auto& e : x.object()) b.set(e.key, e.value);
        return b.build_value();
      }
      case Type::Number: {
        double s = 0;
        for (const Value& x : items) if (!x.is_null()) s += x.number();
        return Value::number(s);
      }
      default: break;
    }
  }
  Value acc;
  for (const Value& x : items) acc = binary_op(BinOp::Add, acc, x);
  return acc;
}

Value builtin_reverse(const Value& v) {
  if (v.is_null()) return Value::array({});
  if (!v.is_array()) throw RuntimeError(std::string("Cannot reverse ") + v.type_name());
  Value::Array out(v.array().rbegin(), v.array().rend());
  return Value::array(std::move(out));
}

Value builtin_min_max(const Value& v, bool max) {
  if (!v.is_array()) throw RuntimeError(std::string(v.type_name()) + " cannot be iterated over");
  const auto& a = v.array();
  if (a.empty()) return Value();
  const Value* best = &a[0];
  for (std::size_t i = 1; i < a.size(); ++i) {
    int c = compare(a[i], *best);
    if (max ? c >= 0 : c < 0) best = &a[i];
  }
  return *best;
}

Value builtin_tostring(const Value& v) {
  if (v.is_string()) return v;
  return Value::string(to_json(v));
}

Value builtin_tonumber(const Value& v) {
  if (v.is_number()) return v;
  if (!v.is_string()) throw RuntimeError(std::string(v.type_name()) + " cannot be parsed as a number");
  const std::string& s = v.string();
  // Validate against the JSON number grammar, then convert.
  std::size_t i = 0, n = s.size();
  auto digits = [&] {
    std::size_t b = i;
    while (i < n && s[i] >= '0' && s[i] <= '9') ++i;
    return i - b;
  };
  if (i < n && s[i] == '-') ++i;
  bool ok = digits() > 0;
  if (ok && i < n && s[i] == '.') { ++i; ok = digits() > 0; }
  if (ok && i < n && (s[i] == 'e' || s[i] == 'E')) {
    ++i;
    if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
    ok = digits() > 0;
  }
  double d = 0;
  if (ok && i == n) {
    auto r = std::from_chars(s.data(), s.data() + n, d);
    ok = r.ec == std::errc() && r.ptr == s.data() + n;
  } else {
    ok = false;
  }
  if (!ok) throw RuntimeError("Cannot parse '" + s + "' as a number");
  return Value::number(d);
}

std::vector<std::size_t> sorted_permutation(const std::vector<Value>& keys) {
  std::vector<std::size_t> idx(keys.size());
  std::iota(idx.begin(), idx.end(), std::size_t{0});
  std::stable_sort(idx.begin(), idx.end(),
                   [&](std::size_t a, std::size_t b) { return compare(keys[a], keys[b]) < 0; });
  return idx;
}

Value builtin_sort(const Value& v) {
  if (!v.is_array()) throw RuntimeError(std::string(v.type_name()) + " cannot be sorted, as it is not an array");
  Value::Array out = v.array();
  std::stable_sort(out.begin(), out.end(), [](const Value& a, const Value& b) { return compare(a, b) < 0; });
  return Value::array(std::move(out));
}

Value builtin_unique(const Value& v) {
  Value sorted = builtin_sort(v);
  Value::Array out;
  for (const Value& x : sorted.array())
    if (out.empty() || compare(out.back(), x) != 0) out.push_back(x);
  return Value::array(std::move(out));
}

}  // namespace jq::detail
