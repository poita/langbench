#include "kiln/builtins.hpp"

#include <algorithm>
#include <functional>
#include <limits>
#include <set>
#include <unordered_map>

#include "kiln/error.hpp"
#include "kiln/glob.hpp"

namespace kiln {

namespace {

enum Mask : unsigned { kStr = 1, kInt = 2, kBool = 4, kList = 8, kAny = 15 };

unsigned mask_of(Type t) {
  switch (t) {
    case Type::Str: return kStr;
    case Type::Int: return kInt;
    case Type::Bool: return kBool;
    case Type::List: return kList;
  }
  return 0;
}

std::string mask_name(unsigned m) {
  std::string out;
  auto add = [&](unsigned bit, const char* n) {
    if (m & bit) {
      if (!out.empty()) out += '|';
      out += n;
    }
  };
  add(kStr, "str");
  add(kInt, "int");
  add(kBool, "bool");
  add(kList, "list");
  return out;
}

using Args = std::vector<Value>;
using Impl = Value (*)(const Args&, const Vfs&);

struct Builtin {
  int min_args;
  int max_args;
  std::vector<unsigned> sig;  // per-argument masks; the last repeats for variadics
  Impl impl;
};

Value S(std::string s) { return Value::string(std::move(s)); }
Value I(std::int64_t i) { return Value::integer(i); }
Value B(bool b) { return Value::boolean(b); }

std::string int_text(std::int64_t v) { return std::to_string(v); }

// --- string helpers -------------------------------------------------------

bool is_trim_byte(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

void substr_window(std::int64_t n, std::int64_t& start, std::int64_t& count) {
  if (start < 0) start += n;
  start = std::clamp<std::int64_t>(start, 0, n);
  count = std::clamp<std::int64_t>(count, 0, n - start);
}

struct BaseParts {
  std::string_view base;
  std::size_t dot;  // npos when no extension
};

BaseParts split_base(std::string_view p) {
  std::size_t slash = p.rfind('/');
  std::string_view b = slash == std::string_view::npos ? p : p.substr(slash + 1);
  std::size_t dot = b.rfind('.');
  if (dot == 0) dot = std::string_view::npos;  // a leading dot is not an extension
  return {b, dot};
}

GlobPattern compile_or_throw(std::string_view fn, const std::string& pat) {
  auto g = GlobPattern::compile(pat);
  if (!g) throw_arg_error("fn", fn, "bad pattern");
  return std::move(*g);
}

Value filter_impl(const Args& a, bool keep_matching, std::string_view fn) {
  GlobPattern g = compile_or_throw(fn, a[1].as_str());
  Value::List out;
  const auto& items = a[0].as_list();
  for (std::size_t i = 0; i < items.size(); ++i) {
    if (!items[i].is(Type::Str)) {
      throw_type_error("fn " + std::string(fn) + " element " + std::to_string(i), "str", items[i].type());
    }
    if (g.matches(items[i].as_str()) == keep_matching) out.push_back(items[i]);
  }
  return Value::list(std::move(out));
}

bool parse_int64(const std::string& s, std::int64_t& out) {
  std::size_t i = 0;
  bool neg = false;
  if (i < s.size() && s[i] == '-') {
    neg = true;
    ++i;
  }
  if (i >= s.size()) return false;
  std::uint64_t limit = neg ? (std::uint64_t{1} << 63) : (std::uint64_t{1} << 63) - 1;
  std::uint64_t v = 0;
  for (; i < s.size(); ++i) {
    if (s[i] < '0' || s[i] > '9') return false;
    std::uint64_t d = static_cast<std::uint64_t>(s[i] - '0');
    if (v > (limit - d) / 10) return false;
    v = v * 10 + d;
  }
  out = neg ? static_cast<std::int64_t>(0 - v) : static_cast<std::int64_t>(v);
  return true;
}

// --- the table ------------------------------------------------------------

const std::unordered_map<std::string_view, Builtin>& table() {
  static const std::unordered_map<std::string_view, Builtin> t = [] {
    std::unordered_map<std::string_view, Builtin> m;
    auto def = [&](std::string_view name, int lo, int hi, std::vector<unsigned> sig, Impl impl) {
      m.emplace(name, Builtin{lo, hi, std::move(sig), impl});
    };

    def("len", 1, 1, {kStr | kList}, [](const Args& a, const Vfs&) {
      return I(a[0].is(Type::Str) ? static_cast<std::int64_t>(a[0].as_str().size())
                                  : static_cast<std::int64_t>(a[0].as_list().size()));
    });
    def("count", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      return I(static_cast<std::int64_t>(a[0].as_list().size()));
    });
    def("upper", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      std::string s = a[0].as_str();
      for (char& c : s) if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 32);
      return S(std::move(s));
    });
    def("lower", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      std::string s = a[0].as_str();
      for (char& c : s) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
      return S(std::move(s));
    });
    def("trim", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      const std::string& s = a[0].as_str();
      std::size_t b = 0, e = s.size();
      while (b < e && is_trim_byte(s[b])) ++b;
      while (e > b && is_trim_byte(s[e - 1])) --e;
      return S(s.substr(b, e - b));
    });
    def("replace", 3, 3, {kStr, kStr, kStr}, [](const Args& a, const Vfs&) {
      if (a[1].as_str().empty()) throw_arg_error("fn", "replace", "empty pattern");
      return S(replace_all(a[0].as_str(), a[1].as_str(), a[2].as_str()));
    });
    def("starts_with", 2, 2, {kStr, kStr}, [](const Args& a, const Vfs&) {
      return B(std::string_view(a[0].as_str()).substr(0, a[1].as_str().size()) == a[1].as_str());
    });
    def("ends_with", 2, 2, {kStr, kStr}, [](const Args& a, const Vfs&) {
      const std::string &s = a[0].as_str(), &x = a[1].as_str();
      return B(s.size() >= x.size() && s.compare(s.size() - x.size(), x.size(), x) == 0);
    });
    def("contains", 2, 2, {kStr, kStr}, [](const Args& a, const Vfs&) {
      return B(a[0].as_str().find(a[1].as_str()) != std::string::npos);
    });
    def("substr", 3, 3, {kStr, kInt, kInt}, [](const Args& a, const Vfs&) {
      const std::string& s = a[0].as_str();
      std::int64_t start = a[1].as_int(), count = a[2].as_int();
      substr_window(static_cast<std::int64_t>(s.size()), start, count);
      return S(s.substr(static_cast<std::size_t>(start), static_cast<std::size_t>(count)));
    });
    def("split", 2, 2, {kStr, kStr}, [](const Args& a, const Vfs&) {
      const std::string &s = a[0].as_str(), &sep = a[1].as_str();
      if (sep.empty()) throw_arg_error("fn", "split", "empty separator");
      Value::List out;
      std::size_t pos = 0;
      while (true) {
        std::size_t f = s.find(sep, pos);
        if (f == std::string::npos) break;
        out.push_back(S(s.substr(pos, f - pos)));
        pos = f + sep.size();
      }
      out.push_back(S(s.substr(pos)));
      return Value::list(std::move(out));
    });
    def("join", 2, 2, {kList, kStr}, [](const Args& a, const Vfs&) {
      const auto& items = a[0].as_list();
      std::string out;
      for (std::size_t i = 0; i < items.size(); ++i) {
        if (i) out += a[1].as_str();
        if (items[i].is(Type::Str)) out += items[i].as_str();
        else if (items[i].is(Type::Int)) out += int_text(items[i].as_int());
        else throw_type_error("fn join element " + std::to_string(i), "str|int", items[i].type());
      }
      return S(std::move(out));
    });
    def("str", 1, 1, {kStr | kInt | kBool}, [](const Args& a, const Vfs&) {
      if (a[0].is(Type::Str)) return a[0];
      if (a[0].is(Type::Int)) return S(int_text(a[0].as_int()));
      return S(a[0].as_bool() ? "true" : "false");
    });
    def("int", 1, 1, {kStr | kInt}, [](const Args& a, const Vfs&) {
      if (a[0].is(Type::Int)) return a[0];
      std::int64_t v;
      if (!parse_int64(a[0].as_str(), v)) throw_arg_error("fn", "int", "bad integer");
      return I(v);
    });
    def("dirname", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      const std::string& s = a[0].as_str();
      std::size_t p = s.rfind('/');
      return S(p == std::string::npos ? std::string() : s.substr(0, p));
    });
    def("basename", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      const std::string& s = a[0].as_str();
      std::size_t p = s.rfind('/');
      return S(p == std::string::npos ? s : s.substr(p + 1));
    });
    def("stem", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      BaseParts bp = split_base(a[0].as_str());
      return S(std::string(bp.dot == std::string_view::npos ? bp.base : bp.base.substr(0, bp.dot)));
    });
    def("ext", 1, 1, {kStr}, [](const Args& a, const Vfs&) {
      BaseParts bp = split_base(a[0].as_str());
      return S(bp.dot == std::string_view::npos ? std::string() : std::string(bp.base.substr(bp.dot)));
    });
    def("pathjoin", 1, 8, {kStr}, [](const Args& a, const Vfs&) {
      std::string out;
      bool first = true;
      for (const Value& v : a) {
        if (v.as_str().empty()) continue;
        if (!first) out += '/';
        out += v.as_str();
        first = false;
      }
      return S(std::move(out));
    });
    def("map", 2, 2, {kList, kStr}, [](const Args& a, const Vfs&) {
      const std::string& pat = a[1].as_str();
      const auto& items = a[0].as_list();
      Value::List out;
      out.reserve(items.size());
      for (std::size_t i = 0; i < items.size(); ++i) {
        if (!items[i].is(Type::Str)) {
          throw_type_error("fn map element " + std::to_string(i), "str", items[i].type());
        }
        std::string r;
        for (std::size_t k = 0; k < pat.size(); ++k) {
          if (pat[k] == '%') {
            if (k + 1 < pat.size() && pat[k + 1] == '%') {
              r += '%';
              ++k;
            } else {
              r += items[i].as_str();
            }
          } else {
            r += pat[k];
          }
        }
        out.push_back(S(std::move(r)));
      }
      return Value::list(std::move(out));
    });
    def("filter", 2, 2, {kList, kStr},
        [](const Args& a, const Vfs&) { return filter_impl(a, true, "filter"); });
    def("reject", 2, 2, {kList, kStr},
        [](const Args& a, const Vfs&) { return filter_impl(a, false, "reject"); });
    def("sort", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      Value::List items = a[0].as_list();
      std::stable_sort(items.begin(), items.end(), ValueLess{});
      return Value::list(std::move(items));
    });
    def("uniq", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      std::set<Value, ValueLess> seen;
      Value::List out;
      for (const Value& v : a[0].as_list()) {
        if (seen.insert(v).second) out.push_back(v);
      }
      return Value::list(std::move(out));
    });
    def("reverse", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      Value::List items = a[0].as_list();
      std::reverse(items.begin(), items.end());
      return Value::list(std::move(items));
    });
    def("first", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      if (a[0].as_list().empty()) throw_arg_error("fn", "first", "empty list");
      return a[0].as_list().front();
    });
    def("last", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      if (a[0].as_list().empty()) throw_arg_error("fn", "last", "empty list");
      return a[0].as_list().back();
    });
    def("slice", 3, 3, {kList, kInt, kInt}, [](const Args& a, const Vfs&) {
      const auto& items = a[0].as_list();
      std::int64_t start = a[1].as_int(), count = a[2].as_int();
      substr_window(static_cast<std::int64_t>(items.size()), start, count);
      auto b = items.begin() + start;
      return Value::list(Value::List(b, b + count));
    });
    def("has", 2, 2, {kList, kAny}, [](const Args& a, const Vfs&) {
      for (const Value& v : a[0].as_list()) {
        if (equal(v, a[1])) return B(true);
      }
      return B(false);
    });
    def("indexof", 2, 2, {kList, kAny}, [](const Args& a, const Vfs&) {
      const auto& items = a[0].as_list();
      for (std::size_t i = 0; i < items.size(); ++i) {
        if (equal(items[i], a[1])) return I(static_cast<std::int64_t>(i));
      }
      return I(-1);
    });
    def("range", 1, 1, {kInt}, [](const Args& a, const Vfs&) {
      std::int64_t n = a[0].as_int();
      if (n < 0) throw_arg_error("fn", "range", "negative");
      Value::List out;
      out.reserve(static_cast<std::size_t>(n));
      for (std::int64_t i = 0; i < n; ++i) out.push_back(I(i));
      return Value::list(std::move(out));
    });
    def("sum", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      std::uint64_t total = 0;
      const auto& items = a[0].as_list();
      for (std::size_t i = 0; i < items.size(); ++i) {
        if (!items[i].is(Type::Int)) {
          throw_type_error("fn sum element " + std::to_string(i), "int", items[i].type());
        }
        total += static_cast<std::uint64_t>(items[i].as_int());
      }
      return I(static_cast<std::int64_t>(total));
    });
    def("flatten", 1, 1, {kList}, [](const Args& a, const Vfs&) {
      Value::List out;
      for (const Value& v : a[0].as_list()) {
        if (v.is(Type::List)) out.insert(out.end(), v.as_list().begin(), v.as_list().end());
        else out.push_back(v);
      }
      return Value::list(std::move(out));
    });
    def("zip", 2, 2, {kList, kList}, [](const Args& a, const Vfs&) {
      const auto &x = a[0].as_list(), &y = a[1].as_list();
      Value::List out;
      for (std::size_t i = 0; i < std::min(x.size(), y.size()); ++i) out.push_back(Value::list({x[i], y[i]}));
      return Value::list(std::move(out));
    });
    def("is_str", 1, 1, {kAny}, [](const Args& a, const Vfs&) { return B(a[0].is(Type::Str)); });
    def("is_int", 1, 1, {kAny}, [](const Args& a, const Vfs&) { return B(a[0].is(Type::Int)); });
    def("is_bool", 1, 1, {kAny}, [](const Args& a, const Vfs&) { return B(a[0].is(Type::Bool)); });
    def("is_list", 1, 1, {kAny}, [](const Args& a, const Vfs&) { return B(a[0].is(Type::List)); });
    def("glob", 1, 1, {kStr}, [](const Args& a, const Vfs& vfs) {
      GlobPattern g = compile_or_throw("glob", a[0].as_str());
      Value::List out;
      for (const std::string& p : vfs.eligible_with_prefix(g.literal_prefix())) {
        if (g.matches(p)) out.push_back(S(p));
      }
      return Value::list(std::move(out));
    });
    return m;
  }();
  return t;
}

}  // namespace

void throw_type_error(std::string_view site, std::string_view expected, Type actual) {
  throw Error(ErrorKind::Type, std::string(site) + ": expected " + std::string(expected) + ", got " +
                                   std::string(type_name(actual)));
}

void throw_arg_error(std::string_view kind, std::string_view name, std::string_view reason) {
  throw Error(ErrorKind::Arg, std::string(kind) + " " + std::string(name) + ": " + std::string(reason));
}

std::string replace_all(std::string_view s, std::string_view from, std::string_view to) {
  std::string out;
  std::size_t i = 0;
  while (i < s.size()) {
    std::size_t f = s.find(from, i);
    if (f == std::string_view::npos) {
      out.append(s.substr(i));
      break;
    }
    out.append(s.substr(i, f - i));
    out.append(to);
    i = f + from.size();
  }
  return out;
}

bool is_builtin(std::string_view name) { return table().find(name) != table().end(); }

Value call_builtin(std::string_view name, const std::vector<Value>& args, const Vfs& vfs) {
  const Builtin& b = table().at(name);
  int n = static_cast<int>(args.size());
  if (n < b.min_args || n > b.max_args) {
    std::string expected = b.min_args == b.max_args
                               ? std::to_string(b.min_args)
                               : std::to_string(b.min_args) + "-" + std::to_string(b.max_args);
    throw Error(ErrorKind::Arity, "fn " + std::string(name) + ": expected " + expected + ", got " +
                                      std::to_string(n));
  }
  for (std::size_t i = 0; i < args.size(); ++i) {
    unsigned mask = b.sig[std::min(i, b.sig.size() - 1)];
    if (mask != kAny && !(mask & mask_of(args[i].type()))) {
      throw_type_error("fn " + std::string(name) + " argument " + std::to_string(i + 1), mask_name(mask),
                       args[i].type());
    }
  }
  return b.impl(args, vfs);
}

}  // namespace kiln
