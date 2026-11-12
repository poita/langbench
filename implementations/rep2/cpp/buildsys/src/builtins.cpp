#include "kiln/builtins.hpp"

#include <algorithm>
#include <unordered_map>
#include <unordered_set>

#include "kiln/error.hpp"
#include "kiln/glob.hpp"

namespace kiln {

namespace {

using Args = std::vector<Value>;
using List = Value::List;

Value S(std::string s) { return Value::string(std::move(s)); }
Value I(std::int64_t i) { return Value::integer(i); }
Value B(bool b) { return Value::boolean(b); }

// ---- strings ----------------------------------------------------------------

Value fnLen(const Args& a, const Vfs&) {
  return I(a[0].isStr() ? static_cast<std::int64_t>(a[0].asStr().size())
                        : static_cast<std::int64_t>(a[0].asList().size()));
}
Value fnCount(const Args& a, const Vfs&) {
  return I(static_cast<std::int64_t>(a[0].asList().size()));
}
Value fnUpper(const Args& a, const Vfs&) {
  std::string s = a[0].asStr();
  for (char& c : s)
    if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 32);
  return S(std::move(s));
}
Value fnLower(const Args& a, const Vfs&) {
  std::string s = a[0].asStr();
  for (char& c : s)
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
  return S(std::move(s));
}
Value fnTrim(const Args& a, const Vfs&) {
  const std::string& s = a[0].asStr();
  auto ws = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; };
  std::size_t b = 0, e = s.size();
  while (b < e && ws(s[b])) ++b;
  while (e > b && ws(s[e - 1])) --e;
  return S(s.substr(b, e - b));
}
Value fnReplace(const Args& a, const Vfs&) {
  const std::string& s = a[0].asStr();
  const std::string& from = a[1].asStr();
  const std::string& to = a[2].asStr();
  if (from.empty()) throw argError("fn", "replace", "empty pattern");
  std::string out;
  std::size_t i = 0;
  while (i < s.size()) {
    std::size_t j = s.find(from, i);
    if (j == std::string::npos) break;
    out.append(s, i, j - i);
    out += to;
    i = j + from.size();
  }
  out.append(s, i, std::string::npos);
  return S(std::move(out));
}
Value fnStartsWith(const Args& a, const Vfs&) {
  const std::string &s = a[0].asStr(), &p = a[1].asStr();
  return B(s.size() >= p.size() && s.compare(0, p.size(), p) == 0);
}
Value fnEndsWith(const Args& a, const Vfs&) {
  const std::string &s = a[0].asStr(), &p = a[1].asStr();
  return B(s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0);
}
Value fnContains(const Args& a, const Vfs&) {
  return B(a[0].asStr().find(a[1].asStr()) != std::string::npos);
}

// Shared clamping of substr / slice.
void clampRange(std::int64_t n, std::int64_t start, std::int64_t count, std::size_t& s,
                std::size_t& c) {
  if (start < 0) start = n + start;
  if (start < 0) start = 0;
  if (start > n) start = n;
  if (count < 0) count = 0;
  if (count > n - start) count = n - start;
  s = static_cast<std::size_t>(start);
  c = static_cast<std::size_t>(count);
}

Value fnSubstr(const Args& a, const Vfs&) {
  const std::string& s = a[0].asStr();
  std::size_t st, c;
  clampRange(static_cast<std::int64_t>(s.size()), a[1].asInt(), a[2].asInt(), st, c);
  return S(s.substr(st, c));
}
Value fnSplit(const Args& a, const Vfs&) {
  const std::string& s = a[0].asStr();
  const std::string& sep = a[1].asStr();
  if (sep.empty()) throw argError("fn", "split", "empty separator");
  List out;
  std::size_t i = 0;
  while (true) {
    std::size_t j = s.find(sep, i);
    if (j == std::string::npos) {
      out.push_back(S(s.substr(i)));
      break;
    }
    out.push_back(S(s.substr(i, j - i)));
    i = j + sep.size();
  }
  return Value::list(std::move(out));
}
Value fnJoin(const Args& a, const Vfs&) {
  const List& l = a[0].asList();
  const std::string& sep = a[1].asStr();
  std::string out;
  for (std::size_t i = 0; i < l.size(); ++i) {
    const Value& v = l[i];
    if (!v.isStr() && !v.isInt())
      throw typeError("fn join element " + std::to_string(i), "str|int", typeName(v.type()));
    if (i) out += sep;
    out += toText(v);
  }
  return S(std::move(out));
}
Value fnStr(const Args& a, const Vfs&) { return S(toText(a[0])); }
Value fnInt(const Args& a, const Vfs&) {
  if (a[0].isInt()) return a[0];
  const std::string& s = a[0].asStr();
  std::size_t i = 0;
  bool neg = false;
  if (i < s.size() && s[i] == '-') {
    neg = true;
    ++i;
  }
  if (i >= s.size()) throw argError("fn", "int", "bad integer");
  unsigned __int128 v = 0;
  for (; i < s.size(); ++i) {
    if (s[i] < '0' || s[i] > '9') throw argError("fn", "int", "bad integer");
    v = v * 10 + static_cast<unsigned>(s[i] - '0');
    if (v > (static_cast<unsigned __int128>(1) << 64)) throw argError("fn", "int", "bad integer");
  }
  unsigned __int128 limit = neg ? (static_cast<unsigned __int128>(1) << 63)
                                : (static_cast<unsigned __int128>(1) << 63) - 1;
  if (v > limit) throw argError("fn", "int", "bad integer");
  std::int64_t r = neg ? static_cast<std::int64_t>(0 - static_cast<std::uint64_t>(v))
                       : static_cast<std::int64_t>(v);
  return I(r);
}

// ---- paths ------------------------------------------------------------------

Value fnDirname(const Args& a, const Vfs&) {
  const std::string& s = a[0].asStr();
  std::size_t i = s.rfind('/');
  return S(i == std::string::npos ? "" : s.substr(0, i));
}
std::string baseOf(const std::string& s) {
  std::size_t i = s.rfind('/');
  return i == std::string::npos ? s : s.substr(i + 1);
}
Value fnBasename(const Args& a, const Vfs&) { return S(baseOf(a[0].asStr())); }
// Index of the extension dot in `b`, or npos.
std::size_t extDot(const std::string& b) {
  std::size_t i = b.rfind('.');
  return (i == std::string::npos || i == 0) ? std::string::npos : i;
}
Value fnStem(const Args& a, const Vfs&) {
  std::string b = baseOf(a[0].asStr());
  std::size_t d = extDot(b);
  return S(d == std::string::npos ? b : b.substr(0, d));
}
Value fnExt(const Args& a, const Vfs&) {
  std::string b = baseOf(a[0].asStr());
  std::size_t d = extDot(b);
  return S(d == std::string::npos ? "" : b.substr(d));
}
Value fnPathjoin(const Args& a, const Vfs&) {
  std::string out;
  bool first = true;
  for (const auto& v : a) {
    if (v.asStr().empty()) continue;
    if (!first) out += '/';
    out += v.asStr();
    first = false;
  }
  return S(std::move(out));
}

// ---- lists ------------------------------------------------------------------

Value fnMap(const Args& a, const Vfs&) {
  const List& l = a[0].asList();
  const std::string& pat = a[1].asStr();
  List out;
  out.reserve(l.size());
  for (std::size_t i = 0; i < l.size(); ++i) {
    if (!l[i].isStr())
      throw typeError("fn map element " + std::to_string(i), "str", typeName(l[i].type()));
    const std::string& e = l[i].asStr();
    std::string r;
    for (std::size_t k = 0; k < pat.size(); ++k) {
      if (pat[k] == '%') {
        if (k + 1 < pat.size() && pat[k + 1] == '%') {
          r += '%';
          ++k;
        } else {
          r += e;
        }
      } else {
        r += pat[k];
      }
    }
    out.push_back(S(std::move(r)));
  }
  return Value::list(std::move(out));
}

Value filterImpl(const Args& a, bool keepMatching, const char* name) {
  auto pat = GlobPattern::compile(a[1].asStr());
  if (!pat) throw argError("fn", name, "bad pattern");
  const List& l = a[0].asList();
  List out;
  for (std::size_t i = 0; i < l.size(); ++i) {
    if (!l[i].isStr())
      throw typeError(std::string("fn ") + name + " element " + std::to_string(i), "str",
                      typeName(l[i].type()));
    if (pat->matches(l[i].asStr()) == keepMatching) out.push_back(l[i]);
  }
  return Value::list(std::move(out));
}
Value fnFilter(const Args& a, const Vfs&) { return filterImpl(a, true, "filter"); }
Value fnReject(const Args& a, const Vfs&) { return filterImpl(a, false, "reject"); }

Value fnSort(const Args& a, const Vfs&) {
  List l = a[0].asList();
  std::stable_sort(l.begin(), l.end(), [](const Value& x, const Value& y) { return compare(x, y) < 0; });
  return Value::list(std::move(l));
}

struct ValueHash {
  std::size_t operator()(const Value& v) const { return hashValue(v); }
};
struct ValueEq {
  bool operator()(const Value& x, const Value& y) const { return equal(x, y); }
};

Value fnUniq(const Args& a, const Vfs&) {
  std::unordered_set<Value, ValueHash, ValueEq> seen;
  List out;
  for (const auto& v : a[0].asList())
    if (seen.insert(v).second) out.push_back(v);
  return Value::list(std::move(out));
}
Value fnReverse(const Args& a, const Vfs&) {
  List l = a[0].asList();
  std::reverse(l.begin(), l.end());
  return Value::list(std::move(l));
}
Value fnFirst(const Args& a, const Vfs&) {
  if (a[0].asList().empty()) throw argError("fn", "first", "empty list");
  return a[0].asList().front();
}
Value fnLast(const Args& a, const Vfs&) {
  if (a[0].asList().empty()) throw argError("fn", "last", "empty list");
  return a[0].asList().back();
}
Value fnSlice(const Args& a, const Vfs&) {
  const List& l = a[0].asList();
  std::size_t st, c;
  clampRange(static_cast<std::int64_t>(l.size()), a[1].asInt(), a[2].asInt(), st, c);
  return Value::list(List(l.begin() + static_cast<std::ptrdiff_t>(st),
                          l.begin() + static_cast<std::ptrdiff_t>(st + c)));
}
Value fnHas(const Args& a, const Vfs&) {
  for (const auto& v : a[0].asList())
    if (equal(v, a[1])) return B(true);
  return B(false);
}
Value fnIndexof(const Args& a, const Vfs&) {
  const List& l = a[0].asList();
  for (std::size_t i = 0; i < l.size(); ++i)
    if (equal(l[i], a[1])) return I(static_cast<std::int64_t>(i));
  return I(-1);
}
Value fnRange(const Args& a, const Vfs&) {
  std::int64_t n = a[0].asInt();
  if (n < 0) throw argError("fn", "range", "negative");
  List out;
  out.reserve(static_cast<std::size_t>(n));
  for (std::int64_t i = 0; i < n; ++i) out.push_back(I(i));
  return Value::list(std::move(out));
}
Value fnSum(const Args& a, const Vfs&) {
  const List& l = a[0].asList();
  std::uint64_t total = 0;
  for (std::size_t i = 0; i < l.size(); ++i) {
    if (!l[i].isInt())
      throw typeError("fn sum element " + std::to_string(i), "int", typeName(l[i].type()));
    total += static_cast<std::uint64_t>(l[i].asInt());
  }
  return I(static_cast<std::int64_t>(total));
}
Value fnFlatten(const Args& a, const Vfs&) {
  List out;
  for (const auto& v : a[0].asList()) {
    if (v.isList()) out.insert(out.end(), v.asList().begin(), v.asList().end());
    else out.push_back(v);
  }
  return Value::list(std::move(out));
}
Value fnZip(const Args& a, const Vfs&) {
  const List &x = a[0].asList(), &y = a[1].asList();
  std::size_t n = std::min(x.size(), y.size());
  List out;
  out.reserve(n);
  for (std::size_t i = 0; i < n; ++i) out.push_back(Value::list(List{x[i], y[i]}));
  return Value::list(std::move(out));
}
Value fnIsStr(const Args& a, const Vfs&) { return B(a[0].isStr()); }
Value fnIsInt(const Args& a, const Vfs&) { return B(a[0].isInt()); }
Value fnIsBool(const Args& a, const Vfs&) { return B(a[0].isBool()); }
Value fnIsList(const Args& a, const Vfs&) { return B(a[0].isList()); }

Value fnGlob(const Args& a, const Vfs& vfs) {
  auto pat = GlobPattern::compile(a[0].asStr());
  if (!pat) throw argError("fn", "glob", "bad pattern");
  List out;
  for (auto& p : vfs.glob(*pat)) out.push_back(S(std::move(p)));
  return Value::list(std::move(out));
}

const std::unordered_map<std::string_view, Builtin>& table() {
  static const std::unordered_map<std::string_view, Builtin> t = [] {
    std::unordered_map<std::string_view, Builtin> m;
    auto add = [&](const char* name, std::vector<unsigned> masks, Builtin::Fn fn) {
      int n = static_cast<int>(masks.size());
      m.emplace(name, Builtin{name, n, n, std::move(masks), fn});
    };
    const unsigned s = kStr, i = kInt, l = kList;
    add("len", {kStr | kList}, fnLen);
    add("count", {l}, fnCount);
    add("upper", {s}, fnUpper);
    add("lower", {s}, fnLower);
    add("trim", {s}, fnTrim);
    add("replace", {s, s, s}, fnReplace);
    add("starts_with", {s, s}, fnStartsWith);
    add("ends_with", {s, s}, fnEndsWith);
    add("contains", {s, s}, fnContains);
    add("substr", {s, i, i}, fnSubstr);
    add("split", {s, s}, fnSplit);
    add("join", {l, s}, fnJoin);
    add("str", {kStr | kInt | kBool}, fnStr);
    add("int", {kStr | kInt}, fnInt);
    add("dirname", {s}, fnDirname);
    add("basename", {s}, fnBasename);
    add("stem", {s}, fnStem);
    add("ext", {s}, fnExt);
    m.emplace("pathjoin", Builtin{"pathjoin", 1, 8, std::vector<unsigned>(8, kStr), fnPathjoin});
    add("map", {l, s}, fnMap);
    add("filter", {l, s}, fnFilter);
    add("reject", {l, s}, fnReject);
    add("sort", {l}, fnSort);
    add("uniq", {l}, fnUniq);
    add("reverse", {l}, fnReverse);
    add("first", {l}, fnFirst);
    add("last", {l}, fnLast);
    add("slice", {l, i, i}, fnSlice);
    add("has", {l, kAny}, fnHas);
    add("indexof", {l, kAny}, fnIndexof);
    add("range", {i}, fnRange);
    add("sum", {l}, fnSum);
    add("flatten", {l}, fnFlatten);
    add("zip", {l, l}, fnZip);
    add("is_str", {kAny}, fnIsStr);
    add("is_int", {kAny}, fnIsInt);
    add("is_bool", {kAny}, fnIsBool);
    add("is_list", {kAny}, fnIsList);
    add("glob", {s}, fnGlob);
    return m;
  }();
  return t;
}

}  // namespace

const Builtin* findBuiltin(std::string_view name) {
  const auto& t = table();
  auto it = t.find(name);
  return it == t.end() ? nullptr : &it->second;
}

Value callBuiltin(const Builtin& fn, const std::vector<Value>& args, const Vfs& vfs) {
  int n = static_cast<int>(args.size());
  if (n < fn.minArgs || n > fn.maxArgs) {
    std::string expected = fn.minArgs == fn.maxArgs
                               ? std::to_string(fn.minArgs)
                               : std::to_string(fn.minArgs) + "-" + std::to_string(fn.maxArgs);
    throw Error("E_ARITY", std::string("fn ") + fn.name + ": expected " + expected + ", got " +
                               std::to_string(n));
  }
  for (std::size_t i = 0; i < args.size(); ++i) {
    unsigned mask = fn.argMasks[i];
    if (!(mask & maskOf(args[i].type())))
      throw typeError(std::string("fn ") + fn.name + " argument " + std::to_string(i + 1),
                      maskName(mask), typeName(args[i].type()));
  }
  return fn.fn(args, vfs);
}

}  // namespace kiln
