#include "ops.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>

#include "jq/json.hpp"

namespace jq::detail {

namespace {

bool fail(std::string* err, const std::string& msg) {
  if (err) *err = msg;
  return false;
}

std::string describe(const Value& v) {
  std::string s = to_json(v);
  if (s.size() > 11) s = s.substr(0, 10) + "...";
  return std::string(v.type_name()) + " (" + s + ")";
}

bool is_cont(char c) { return (static_cast<unsigned char>(c) & 0xC0) == 0x80; }

// Byte offset of the code point with index `cp` (or size() if past the end).
std::size_t byte_offset(const std::string& s, std::size_t cp) {
  std::size_t i = 0;
  while (i < s.size() && cp > 0) {
    ++i;
    while (i < s.size() && is_cont(s[i])) ++i;
    --cp;
  }
  return i;
}

// Shallow merge, right wins. When `b` is small, scanning the copy of `a` for
// each of its keys is cheaper than hashing all of `a` (this keeps
// `reduce ... (. + {k: v})` fast); otherwise use a hashed builder.
Value add_objects(const Object& a, const Object& b) {
  constexpr std::size_t kSmall = 4;
  if (b.size() > kSmall) {
    ObjectBuilder builder(a);
    for (const Member& m : b.members()) builder.set(m.key, m.value);
    return builder.build();
  }
  std::vector<Member> members;
  members.reserve(a.size() + b.size());
  members.insert(members.end(), a.members().begin(), a.members().end());
  const std::size_t base = a.size();
  for (const Member& m : b.members()) {
    bool found = false;
    for (std::size_t i = 0; i < base; ++i)
      if (members[i].key == m.key) {
        members[i].value = m.value;
        found = true;
        break;
      }
    if (!found) members.push_back(m);  // `b` has distinct keys, so only `a` can collide
  }
  return Value::object(std::move(members));
}

Value merge_deep(const Value& a, const Value& b) {
  const Object& ao = a.as_object();
  ObjectBuilder builder(ao);
  for (const Member& m : b.as_object().members()) {
    const Value* existing = ao.find(m.key);
    if (existing && existing->is_object() && m.value.is_object())
      builder.set(m.key, merge_deep(*existing, m.value));
    else
      builder.set(m.key, m.value);
  }
  return builder.build();
}

long long truncate_int(double d) {
  if (d >= 9.2e18) return 9200000000000000000LL;
  if (d <= -9.2e18) return -9200000000000000000LL;
  return static_cast<long long>(d);
}

Value split_string(const std::string& s, const std::string& sep) {
  std::vector<Value> parts;
  if (s.empty()) return Value::array({});
  if (sep.empty()) {
    for (std::size_t i = 0; i < s.size();) {
      std::size_t j = i + 1;
      while (j < s.size() && is_cont(s[j])) ++j;
      parts.push_back(Value::string(s.substr(i, j - i)));
      i = j;
    }
    return Value::array(std::move(parts));
  }
  std::size_t start = 0;
  for (;;) {
    std::size_t p = s.find(sep, start);
    if (p == std::string::npos) {
      parts.push_back(Value::string(s.substr(start)));
      break;
    }
    parts.push_back(Value::string(s.substr(start, p - start)));
    start = p + sep.size();
  }
  return Value::array(std::move(parts));
}

Value subtract_arrays(const Value& l, const Value& r) {
  const auto& a = l.as_array();
  const auto& b = r.as_array();
  std::vector<Value> out;
  if (b.size() <= 8) {
    for (const Value& x : a) {
      bool found = false;
      for (const Value& y : b)
        if (compare(x, y) == 0) {
          found = true;
          break;
        }
      if (!found) out.push_back(x);
    }
  } else {
    std::vector<const Value*> sorted;
    sorted.reserve(b.size());
    for (const Value& y : b) sorted.push_back(&y);
    std::sort(sorted.begin(), sorted.end(), [](const Value* x, const Value* y) { return compare(*x, *y) < 0; });
    for (const Value& x : a) {
      auto it = std::lower_bound(sorted.begin(), sorted.end(), &x,
                                 [](const Value* p, const Value* q) { return compare(*p, *q) < 0; });
      if (it == sorted.end() || compare(**it, x) != 0) out.push_back(x);
    }
  }
  return Value::array(std::move(out));
}

}  // namespace

std::size_t utf8_length(const std::string& s) {
  std::size_t n = 0;
  for (char c : s)
    if (!is_cont(c)) ++n;
  return n;
}

bool binary_op(BinOp op, const Value& l, const Value& r, Value& out, std::string* err) {
  switch (op) {
    case BinOp::Eq: out = Value::boolean(compare(l, r) == 0); return true;
    case BinOp::Ne: out = Value::boolean(compare(l, r) != 0); return true;
    case BinOp::Lt: out = Value::boolean(compare(l, r) < 0); return true;
    case BinOp::Le: out = Value::boolean(compare(l, r) <= 0); return true;
    case BinOp::Gt: out = Value::boolean(compare(l, r) > 0); return true;
    case BinOp::Ge: out = Value::boolean(compare(l, r) >= 0); return true;
    case BinOp::Add:
      if (l.is_number() && r.is_number()) {
        out = Value::number(l.as_number() + r.as_number());
        return true;
      }
      if (l.is_null()) {
        out = r;
        return true;
      }
      if (r.is_null()) {
        out = l;
        return true;
      }
      if (l.is_string() && r.is_string()) {
        out = Value::string(l.as_string() + r.as_string());
        return true;
      }
      if (l.is_array() && r.is_array()) {
        std::vector<Value> v;
        v.reserve(l.as_array().size() + r.as_array().size());
        v.insert(v.end(), l.as_array().begin(), l.as_array().end());
        v.insert(v.end(), r.as_array().begin(), r.as_array().end());
        out = Value::array(std::move(v));
        return true;
      }
      if (l.is_object() && r.is_object()) {
        out = add_objects(l.as_object(), r.as_object());
        return true;
      }
      return fail(err, describe(l) + " and " + describe(r) + " cannot be added");
    case BinOp::Sub:
      if (l.is_number() && r.is_number()) {
        out = Value::number(l.as_number() - r.as_number());
        return true;
      }
      if (l.is_array() && r.is_array()) {
        out = subtract_arrays(l, r);
        return true;
      }
      return fail(err, describe(l) + " and " + describe(r) + " cannot be subtracted");
    case BinOp::Mul:
      if (l.is_number() && r.is_number()) {
        out = Value::number(l.as_number() * r.as_number());
        return true;
      }
      if ((l.is_string() && r.is_number()) || (l.is_number() && r.is_string())) {
        const Value& s = l.is_string() ? l : r;
        double n = (l.is_string() ? r : l).as_number();
        if (!(n >= 0)) {
          out = Value();
          return true;
        }
        std::size_t count = static_cast<std::size_t>(truncate_int(n));
        std::string res;
        res.reserve(s.as_string().size() * count);
        for (std::size_t i = 0; i < count; ++i) res += s.as_string();
        out = Value::string(std::move(res));
        return true;
      }
      if (l.is_object() && r.is_object()) {
        out = merge_deep(l, r);
        return true;
      }
      return fail(err, describe(l) + " and " + describe(r) + " cannot be multiplied");
    case BinOp::Div:
      if (l.is_number() && r.is_number()) {
        if (r.as_number() == 0)
          return fail(err, describe(l) + " and " + describe(r) + " cannot be divided because the divisor is zero");
        out = Value::number(l.as_number() / r.as_number());
        return true;
      }
      if (l.is_string() && r.is_string()) {
        out = split_string(l.as_string(), r.as_string());
        return true;
      }
      return fail(err, describe(l) + " and " + describe(r) + " cannot be divided");
    case BinOp::Mod:
      if (l.is_number() && r.is_number()) {
        long long a = truncate_int(l.as_number());
        long long b = truncate_int(r.as_number());
        if (b == 0)
          return fail(err, describe(l) + " and " + describe(r) + " cannot be divided because the divisor is zero");
        out = Value::number(b == -1 ? 0.0 : static_cast<double>(a % b));
        return true;
      }
      return fail(err, describe(l) + " and " + describe(r) + " cannot be divided");
  }
  return false;
}

bool index_value(const Value& t, const Value& k, Value& out, std::string* err) {
  if (k.is_string()) {
    if (t.is_object()) {
      const Value* v = t.as_object().find(k.as_string());
      out = v ? *v : Value();
      return true;
    }
    if (t.is_null()) {
      out = Value();
      return true;
    }
    return fail(err, std::string("Cannot index ") + t.type_name() + " with string \"" + k.as_string() + "\"");
  }
  if (k.is_number()) {
    if (t.is_array()) {
      const auto& a = t.as_array();
      double d = std::trunc(k.as_number());
      if (d < 0) d += static_cast<double>(a.size());
      out = (d >= 0 && d < static_cast<double>(a.size())) ? a[static_cast<std::size_t>(d)] : Value();
      return true;
    }
    if (t.is_null()) {
      out = Value();
      return true;
    }
    return fail(err, std::string("Cannot index ") + t.type_name() + " with number");
  }
  return fail(err, std::string("Cannot index ") + t.type_name() + " with " + k.type_name());
}

bool slice_value(const Value& t, const Value* from, const Value* to, Value& out, std::string* err) {
  if ((from && !from->is_number()) || (to && !to->is_number()))
    return fail(err, "Start and end indices of an array slice must be numbers");
  if (t.is_null()) {
    out = Value();
    return true;
  }
  if (!t.is_array() && !t.is_string()) return fail(err, std::string("Cannot index ") + t.type_name() + " with object");
  double len = static_cast<double>(t.is_array() ? t.as_array().size() : utf8_length(t.as_string()));
  double s = from ? std::floor(from->as_number()) : 0;
  double e = to ? std::ceil(to->as_number()) : len;
  if (s < 0) s += len;
  if (e < 0) e += len;
  s = std::clamp(s, 0.0, len);
  e = std::clamp(e, 0.0, len);
  if (e < s) e = s;
  auto si = static_cast<std::size_t>(s), ei = static_cast<std::size_t>(e);
  if (t.is_array()) {
    const auto& a = t.as_array();
    out = Value::array(std::vector<Value>(a.begin() + static_cast<std::ptrdiff_t>(si),
                                          a.begin() + static_cast<std::ptrdiff_t>(ei)));
  } else {
    const std::string& str = t.as_string();
    std::size_t b0 = byte_offset(str, si);
    std::size_t b1 = b0 + byte_offset(str.substr(b0), ei - si);
    out = Value::string(str.substr(b0, b1 - b0));
  }
  return true;
}

bool value_length(const Value& v, Value& out, std::string* err) {
  switch (v.type()) {
    case Type::Null: out = Value::number(0); return true;
    case Type::Number: out = Value::number(std::fabs(v.as_number())); return true;
    case Type::String: out = Value::number(static_cast<double>(utf8_length(v.as_string()))); return true;
    case Type::Array: out = Value::number(static_cast<double>(v.as_array().size())); return true;
    case Type::Object: out = Value::number(static_cast<double>(v.as_object().size())); return true;
    default: return fail(err, describe(v) + " has no length");
  }
}

bool value_keys(const Value& v, Value& out, std::string* err) {
  if (v.is_object()) {
    const Object& o = v.as_object();
    std::vector<Value> keys;
    keys.reserve(o.size());
    for (std::uint32_t i : o.sorted_order()) keys.push_back(Value::string(o.members()[i].key));
    out = Value::array(std::move(keys));
    return true;
  }
  if (v.is_array()) {
    std::vector<Value> keys;
    keys.reserve(v.as_array().size());
    for (std::size_t i = 0; i < v.as_array().size(); ++i) keys.push_back(Value::number(static_cast<double>(i)));
    out = Value::array(std::move(keys));
    return true;
  }
  return fail(err, describe(v) + " has no keys");
}

bool value_has(const Value& v, const Value& k, bool& out, std::string* err) {
  if (v.is_null()) {
    out = false;
    return true;
  }
  if (v.is_object() && k.is_string()) {
    out = v.as_object().find(k.as_string()) != nullptr;
    return true;
  }
  if (v.is_array() && k.is_number()) {
    double d = std::trunc(k.as_number());
    out = d >= 0 && d < static_cast<double>(v.as_array().size());
    return true;
  }
  return fail(err, std::string("Cannot check whether ") + v.type_name() + " has a " + k.type_name() + " key");
}

bool value_add(const Value& v, Value& out, std::string* err) {
  // Equivalent to `reduce .[] as $x (null; . + $x)`, but accumulating in
  // place so that long runs of strings/arrays/objects stay linear.
  const std::vector<Value>* arr = nullptr;
  std::vector<Value> vals;
  if (v.is_array()) {
    arr = &v.as_array();
  } else if (v.is_object()) {
    for (const Member& m : v.as_object().members()) vals.push_back(m.value);
    arr = &vals;
  } else {
    return fail(err, std::string("Cannot iterate over ") + v.type_name());
  }
  enum { None, Num, Str, Arr, Obj, Other } mode = None;
  double num = 0;
  std::string str;
  std::vector<Value> items;
  ObjectBuilder obj;
  Value first;
  for (const Value& x : *arr) {
    if (x.is_null()) continue;
    if (mode == None) {
      first = x;
      mode = x.is_number() ? Num : x.is_string() ? Str : x.is_array() ? Arr : x.is_object() ? Obj : Other;
      if (mode == Num) num = x.as_number();
      else if (mode == Str) str = x.as_string();
      else if (mode == Arr) items = x.as_array();
      else if (mode == Obj) obj = ObjectBuilder(x.as_object());
      continue;
    }
    if (mode == Num && x.is_number()) num += x.as_number();
    else if (mode == Str && x.is_string()) str += x.as_string();
    else if (mode == Arr && x.is_array()) items.insert(items.end(), x.as_array().begin(), x.as_array().end());
    else if (mode == Obj && x.is_object()) {
      for (const Member& m : x.as_object().members()) obj.set(m.key, m.value);
    } else {
      return fail(err, describe(first) + " and " + describe(x) + " cannot be added");
    }
  }
  switch (mode) {
    case None: out = Value(); break;
    case Num: out = Value::number(num); break;
    case Str: out = Value::string(std::move(str)); break;
    case Arr: out = Value::array(std::move(items)); break;
    case Obj: out = obj.build(); break;
    case Other:
      out = first;  // a lone boolean: `null + true` is true
      break;
  }
  return true;
}

bool value_reverse(const Value& v, Value& out, std::string* err) {
  if (v.is_null()) {
    out = Value::array({});
    return true;
  }
  if (!v.is_array()) return fail(err, std::string("Cannot reverse ") + v.type_name());
  const auto& a = v.as_array();
  out = Value::array(std::vector<Value>(a.rbegin(), a.rend()));
  return true;
}

bool value_min_max(const Value& v, bool want_max, Value& out, std::string* err) {
  if (!v.is_array()) return fail(err, describe(v) + " cannot be iterated over");
  const auto& a = v.as_array();
  if (a.empty()) {
    out = Value();
    return true;
  }
  const Value* best = &a[0];
  for (std::size_t i = 1; i < a.size(); ++i) {
    int c = compare(a[i], *best);
    if (want_max ? c >= 0 : c < 0) best = &a[i];
  }
  out = *best;
  return true;
}

Value value_tostring(const Value& v) { return v.is_string() ? v : Value::string(to_json(v)); }

bool value_tonumber(const Value& v, Value& out, std::string* err) {
  if (v.is_number()) {
    out = v;
    return true;
  }
  if (v.is_string()) {
    const std::string& s = v.as_string();
    // Strict JSON number grammar.
    std::size_t i = 0, n = s.size();
    auto digits = [&] {
      std::size_t b = i;
      while (i < n && s[i] >= '0' && s[i] <= '9') ++i;
      return i > b;
    };
    bool ok = true;
    if (i < n && s[i] == '-') ++i;
    ok = digits();
    if (ok && i < n && s[i] == '.') {
      ++i;
      ok = digits();
    }
    if (ok && i < n && (s[i] == 'e' || s[i] == 'E')) {
      ++i;
      if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
      ok = digits();
    }
    double d = 0;
    if (ok && i == n && std::from_chars(s.data(), s.data() + n, d).ec == std::errc()) {
      out = Value::number(d);
      return true;
    }
    return fail(err, "Cannot parse '" + s + "' as a number");
  }
  return fail(err, describe(v) + " cannot be parsed as a number");
}

std::vector<std::size_t> stable_order(const std::vector<Value>& keys) {
  std::vector<std::size_t> idx(keys.size());
  for (std::size_t i = 0; i < idx.size(); ++i) idx[i] = i;
  std::stable_sort(idx.begin(), idx.end(), [&](std::size_t a, std::size_t b) { return compare(keys[a], keys[b]) < 0; });
  return idx;
}

bool value_sort(const Value& v, Value& out, std::string* err) {
  if (!v.is_array()) return fail(err, describe(v) + " cannot be sorted, as it is not an array");
  std::vector<Value> items = v.as_array();
  std::stable_sort(items.begin(), items.end(), [](const Value& a, const Value& b) { return compare(a, b) < 0; });
  out = Value::array(std::move(items));
  return true;
}

bool value_unique(const Value& v, Value& out, std::string* err) {
  Value sorted;
  if (!value_sort(v, sorted, err)) return false;
  std::vector<Value> items;
  for (const Value& x : sorted.as_array())
    if (items.empty() || compare(items.back(), x) != 0) items.push_back(x);
  out = Value::array(std::move(items));
  return true;
}

}  // namespace jq::detail
