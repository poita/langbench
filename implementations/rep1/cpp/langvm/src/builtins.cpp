#include "builtins.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <unordered_map>

#include "numfmt.h"
#include "utf8.h"
#include "vm.h"

namespace langvm {
namespace {

// The prelude declares Option and Result first, so they are declarations 0 and 1.
constexpr uint32_t kOptionDecl = 0;

#define BI(name) Value bi_##name(VM& vm, Value* a)
#define UNUSED_VM (void)vm

// ------------------------------------------------------------------ helpers

Value mkEnum(uint32_t decl, uint8_t variant, Value payload) {
  Value v = newArr(VT::Enum, 1, decl, variant);
  arrOf(v).items()[0] = std::move(payload);
  return v;
}
Value mkNone() {
  Value v;
  v.t = VT::Enum;
  v.decl = kOptionDecl;
  v.variant = 1;
  return v;
}
Value mkSome(Value x) { return mkEnum(kOptionDecl, 0, std::move(x)); }
Value mkStr(const std::string& utf8) { return newStr(decodeUtf8(utf8)); }
Value mkPair(Value x, Value y) {
  Value t = newArr(VT::Tuple, 2);
  arrOf(t).items()[0] = std::move(x);
  arrOf(t).items()[1] = std::move(y);
  return t;
}
Value mkBool(bool b) { return Value::ofBool(b); }
Value mkInt(int64_t i) { return Value::ofInt(i); }

const std::u32string& S(const Value& v) { return strOf(v); }

bool isSpaceC(char32_t c) { return c == 9 || c == 10 || c == 11 || c == 12 || c == 13 || c == 32; }
bool isDigitC(char32_t c) { return c >= '0' && c <= '9'; }
bool isAlphaC(char32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }

int cmp3(int64_t x, int64_t y) { return x < y ? -1 : x > y ? 1 : 0; }

// ------------------------------------------------------------- output

BI(print) {
  vm.write(S(a[0]));
  vm.write(U"\n");
  return Value();
}
BI(emit) {
  vm.write(S(a[0]));
  return Value();
}
BI(panic) { vm.panic(encodeUtf8(S(a[0]))); }

// ----------------------------------------------------------- integers

BI(intMin) { UNUSED_VM; (void)a; return mkInt(INT64_MIN); }
BI(intMax) { UNUSED_VM; (void)a; return mkInt(INT64_MAX); }
BI(absI) { UNUSED_VM; int64_t x = a[0].asInt(); return mkInt(x < 0 ? static_cast<int64_t>(0 - static_cast<uint64_t>(x)) : x); }
BI(minI) { UNUSED_VM; return mkInt(std::min(a[0].asInt(), a[1].asInt())); }
BI(maxI) { UNUSED_VM; return mkInt(std::max(a[0].asInt(), a[1].asInt())); }
BI(signI) { UNUSED_VM; return mkInt(cmp3(a[0].asInt(), 0)); }
BI(cmpI) { UNUSED_VM; return mkInt(cmp3(a[0].asInt(), a[1].asInt())); }

int64_t divFloorImpl(VM& vm, int64_t x, int64_t y) {
  if (y == 0) vm.panic("divide by zero");
  if (y == -1) return static_cast<int64_t>(0 - static_cast<uint64_t>(x));
  int64_t q = x / y;
  if ((x % y != 0) && ((x < 0) != (y < 0))) --q;
  return q;
}
BI(divFloor) { return mkInt(divFloorImpl(vm, a[0].asInt(), a[1].asInt())); }
BI(modFloor) {
  int64_t x = a[0].asInt(), y = a[1].asInt();
  if (y == 0) vm.panic("modulo by zero");
  if (y == -1) return mkInt(0);
  int64_t r = x % y;
  if (r != 0 && ((r < 0) != (y < 0))) r += y;
  return mkInt(r);
}
BI(powI) {
  int64_t base = a[0].asInt(), e = a[1].asInt();
  if (e < 0) vm.panic("negative exponent");
  uint64_t r = 1, b = static_cast<uint64_t>(base);
  while (e > 0) {
    if (e & 1) r *= b;
    e >>= 1;
    if (e > 0) b *= b;
  }
  return mkInt(static_cast<int64_t>(r));
}
BI(gcdI) {
  UNUSED_VM;
  auto mag = [](int64_t v) { return v < 0 ? 0 - static_cast<uint64_t>(v) : static_cast<uint64_t>(v); };
  uint64_t x = mag(a[0].asInt()), y = mag(a[1].asInt());
  while (y) {
    uint64_t t = x % y;
    x = y;
    y = t;
  }
  return mkInt(static_cast<int64_t>(x));
}
BI(popCount) { UNUSED_VM; return mkInt(__builtin_popcountll(static_cast<uint64_t>(a[0].asInt()))); }
BI(clz) { UNUSED_VM; uint64_t x = static_cast<uint64_t>(a[0].asInt()); return mkInt(x ? __builtin_clzll(x) : 64); }
BI(ctz) { UNUSED_VM; uint64_t x = static_cast<uint64_t>(a[0].asInt()); return mkInt(x ? __builtin_ctzll(x) : 64); }
BI(toFloat) { UNUSED_VM; return Value::ofFloat(static_cast<double>(a[0].asInt())); }
BI(showInt) { UNUSED_VM; return mkStr(std::to_string(a[0].asInt())); }
BI(showIntRadix) {
  int64_t r = a[1].asInt();
  if (r < 2 || r > 36) vm.panic("radix out of range");
  return mkStr(formatIntRadix(a[0].asInt(), static_cast<int>(r)));
}
BI(parseInt) {
  UNUSED_VM;
  int64_t v;
  return parseIntText(S(a[0]), 10, v) ? mkSome(mkInt(v)) : mkNone();
}
BI(parseIntRadix) {
  int64_t r = a[1].asInt();
  if (r < 2 || r > 36) vm.panic("radix out of range");
  int64_t v;
  return parseIntText(S(a[0]), static_cast<int>(r), v) ? mkSome(mkInt(v)) : mkNone();
}

// ------------------------------------------------------------- floats

double F(const Value& v) { return v.asFloat(); }
Value mkF(double d) { return Value::ofFloat(d); }

BI(sqrtF) { UNUSED_VM; return mkF(std::sqrt(F(a[0]))); }
BI(absF) { UNUSED_VM; return mkF(std::fabs(F(a[0]))); }
BI(floorF) { UNUSED_VM; return mkF(std::floor(F(a[0]))); }
BI(ceilF) { UNUSED_VM; return mkF(std::ceil(F(a[0]))); }
BI(truncF) { UNUSED_VM; return mkF(std::trunc(F(a[0]))); }
BI(roundF) { UNUSED_VM; return mkF(std::round(F(a[0]))); }

int cmpFImpl(double x, double y) {
  bool nx = std::isnan(x), ny = std::isnan(y);
  if (nx || ny) return nx && ny ? 0 : nx ? 1 : -1;
  return x < y ? -1 : x > y ? 1 : 0;
}
BI(minF) { UNUSED_VM; return cmpFImpl(F(a[0]), F(a[1])) <= 0 ? a[0] : a[1]; }
BI(maxF) { UNUSED_VM; return cmpFImpl(F(a[0]), F(a[1])) >= 0 ? a[0] : a[1]; }
BI(fmodF) { UNUSED_VM; return mkF(std::fmod(F(a[0]), F(a[1]))); }
double powFImpl(double x, int64_t n) {
  double r = 1.0, b = x;
  int64_t k = n;
  while (k > 0) {
    if (k & 1) r = r * b;
    k >>= 1;
    if (k > 0) b = b * b;
  }
  return r;
}
BI(powF) {
  double x = F(a[0]);
  int64_t n = a[1].asInt();
  if (n == INT64_MIN) vm.panic("negative exponent");
  if (n < 0) return mkF(1.0 / powFImpl(x, -n));
  return mkF(powFImpl(x, n));
}
BI(isNanF) { UNUSED_VM; return mkBool(std::isnan(F(a[0]))); }
BI(isInfF) { UNUSED_VM; return mkBool(std::isinf(F(a[0]))); }
BI(cmpF) { UNUSED_VM; return mkInt(cmpFImpl(F(a[0]), F(a[1]))); }
BI(truncToInt) {
  double t = std::trunc(F(a[0]));
  if (std::isnan(t) || t >= 9223372036854775808.0 || t < -9223372036854775808.0) vm.panic("float out of integer range");
  return mkInt(static_cast<int64_t>(t));
}
BI(showFloat) { UNUSED_VM; return mkStr(formatFloatFixed(F(a[0]), 6)); }
BI(showFloatAt) {
  int64_t d = a[1].asInt();
  if (d < 0 || d > 17) vm.panic("digits out of range");
  return mkStr(formatFloatFixed(F(a[0]), static_cast<int>(d)));
}
BI(floatBits) {
  UNUSED_VM;
  int64_t b;
  double d = F(a[0]);
  std::memcpy(&b, &d, sizeof b);
  return mkInt(b);
}
BI(floatFromBits) {
  UNUSED_VM;
  int64_t b = a[0].asInt();
  double d;
  std::memcpy(&d, &b, sizeof d);
  return mkF(d);
}
BI(parseFloat) {
  UNUSED_VM;
  double d;
  return parseFloatText(S(a[0]), d) ? mkSome(mkF(d)) : mkNone();
}
BI(infF) { UNUSED_VM; (void)a; return mkF(HUGE_VAL); }
BI(nanF) {
  UNUSED_VM; (void)a;
  uint64_t b = 0x7ff8000000000000ull;
  double d;
  std::memcpy(&d, &b, sizeof d);
  return mkF(d);
}
BI(piF) {
  UNUSED_VM; (void)a;
  int64_t b = 4614256656552045848;
  double d;
  std::memcpy(&d, &b, sizeof d);
  return mkF(d);
}

// ---------------------------------------------------------- bools, chars

void escapeInto(std::u32string& out, char32_t c, char32_t quote) {
  if (c == '\\') out += U"\\\\";
  else if (c == quote) { out.push_back('\\'); out.push_back(quote); }
  else if (c == '\n') out += U"\\n";
  else if (c == '\r') out += U"\\r";
  else if (c == '\t') out += U"\\t";
  else if (c < 0x20 || c == 0x7F) {
    out += U"\\u{";
    out += decodeUtf8(formatIntRadix(static_cast<int64_t>(c), 16));
    out.push_back('}');
  } else out.push_back(c);
}

BI(showBool) { UNUSED_VM; return mkStr(a[0].asBool() ? "true" : "false"); }
BI(ord) { UNUSED_VM; return mkInt(a[0].asInt()); }
BI(chr) {
  int64_t n = a[0].asInt();
  if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) vm.panic("invalid char code");
  return Value::ofChar(static_cast<char32_t>(n));
}
BI(isDigit) { UNUSED_VM; return mkBool(isDigitC(a[0].asChar())); }
BI(isAlpha) { UNUSED_VM; return mkBool(isAlphaC(a[0].asChar())); }
BI(isAlnum) { UNUSED_VM; return mkBool(isAlphaC(a[0].asChar()) || isDigitC(a[0].asChar())); }
BI(isSpace) { UNUSED_VM; return mkBool(isSpaceC(a[0].asChar())); }
BI(isUpper) { UNUSED_VM; char32_t c = a[0].asChar(); return mkBool(c >= 'A' && c <= 'Z'); }
BI(isLower) { UNUSED_VM; char32_t c = a[0].asChar(); return mkBool(c >= 'a' && c <= 'z'); }
BI(toUpperC) { UNUSED_VM; char32_t c = a[0].asChar(); return Value::ofChar(c >= 'a' && c <= 'z' ? c - 32 : c); }
BI(toLowerC) { UNUSED_VM; char32_t c = a[0].asChar(); return Value::ofChar(c >= 'A' && c <= 'Z' ? c + 32 : c); }
BI(cmpC) { UNUSED_VM; return mkInt(cmp3(a[0].asInt(), a[1].asInt())); }
BI(showChar) { UNUSED_VM; return newStr(std::u32string(1, a[0].asChar())); }
BI(quoteChar) {
  UNUSED_VM;
  std::u32string s = U"'";
  escapeInto(s, a[0].asChar(), '\'');
  s.push_back('\'');
  return newStr(std::move(s));
}

// ------------------------------------------------------------- strings

BI(strLen) { UNUSED_VM; return mkInt(static_cast<int64_t>(S(a[0]).size())); }
BI(charAt) {
  const auto& s = S(a[0]);
  int64_t i = a[1].asInt();
  if (i < 0 || static_cast<uint64_t>(i) >= s.size()) vm.panic("index out of bounds");
  return Value::ofChar(s[static_cast<size_t>(i)]);
}
BI(substr) {
  const auto& s = S(a[0]);
  int64_t from = a[1].asInt(), to = a[2].asInt();
  if (from < 0 || from > to || static_cast<uint64_t>(to) > s.size()) vm.panic("index out of bounds");
  return newStr(s.substr(static_cast<size_t>(from), static_cast<size_t>(to - from)));
}
BI(strCat) { UNUSED_VM; return newStr(S(a[0]) + S(a[1])); }
BI(strRepeat) {
  int64_t n = a[1].asInt();
  if (n < 0) vm.panic("negative count");
  std::u32string r;
  r.reserve(S(a[0]).size() * static_cast<size_t>(n));
  for (int64_t i = 0; i < n; ++i) r += S(a[0]);
  return newStr(std::move(r));
}
BI(strIndexOf) {
  UNUSED_VM;
  size_t p = S(a[0]).find(S(a[1]));
  return mkInt(p == std::u32string::npos ? -1 : static_cast<int64_t>(p));
}
BI(strLastIndexOf) {
  UNUSED_VM;
  size_t p = S(a[0]).rfind(S(a[1]));
  return mkInt(p == std::u32string::npos ? -1 : static_cast<int64_t>(p));
}
BI(strContains) { UNUSED_VM; return mkBool(S(a[0]).find(S(a[1])) != std::u32string::npos); }
BI(startsWith) {
  UNUSED_VM;
  const auto &s = S(a[0]), &p = S(a[1]);
  return mkBool(s.size() >= p.size() && s.compare(0, p.size(), p) == 0);
}
BI(endsWith) {
  UNUSED_VM;
  const auto &s = S(a[0]), &p = S(a[1]);
  return mkBool(s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0);
}
BI(strSplit) {
  const auto &s = S(a[0]), &sep = S(a[1]);
  if (sep.empty()) vm.panic("empty separator");
  std::vector<Value> parts;
  size_t start = 0;
  for (;;) {
    size_t p = s.find(sep, start);
    if (p == std::u32string::npos) {
      parts.push_back(newStr(s.substr(start)));
      break;
    }
    parts.push_back(newStr(s.substr(start, p - start)));
    start = p + sep.size();
  }
  return newList(std::move(parts));
}
BI(strJoin) {
  UNUSED_VM;
  const auto& l = listOf(a[0]);
  const auto& sep = S(a[1]);
  std::u32string r;
  for (size_t i = 0; i < l.size(); ++i) {
    if (i) r += sep;
    r += S(l[i]);
  }
  return newStr(std::move(r));
}
BI(strReplace) {
  const auto &s = S(a[0]), &from = S(a[1]), &to = S(a[2]);
  if (from.empty()) vm.panic("empty separator");
  std::u32string r;
  size_t i = 0;
  while (i < s.size()) {
    if (s.compare(i, from.size(), from) == 0) {
      r += to;
      i += from.size();
    } else {
      r.push_back(s[i++]);
    }
  }
  return newStr(std::move(r));
}
Value trimImpl(const std::u32string& s, bool left, bool right) {
  size_t b = 0, e = s.size();
  if (left)
    while (b < e && isSpaceC(s[b])) ++b;
  if (right)
    while (e > b && isSpaceC(s[e - 1])) --e;
  return newStr(s.substr(b, e - b));
}
BI(trim) { UNUSED_VM; return trimImpl(S(a[0]), true, true); }
BI(trimLeft) { UNUSED_VM; return trimImpl(S(a[0]), true, false); }
BI(trimRight) { UNUSED_VM; return trimImpl(S(a[0]), false, true); }
BI(upper) {
  UNUSED_VM;
  std::u32string s = S(a[0]);
  for (auto& c : s)
    if (c >= 'a' && c <= 'z') c -= 32;
  return newStr(std::move(s));
}
BI(lower) {
  UNUSED_VM;
  std::u32string s = S(a[0]);
  for (auto& c : s)
    if (c >= 'A' && c <= 'Z') c += 32;
  return newStr(std::move(s));
}
BI(strCmp) {
  UNUSED_VM;
  int c = S(a[0]).compare(S(a[1]));
  return mkInt(c < 0 ? -1 : c > 0 ? 1 : 0);
}
BI(chars) {
  UNUSED_VM;
  std::vector<Value> v;
  for (char32_t c : S(a[0])) v.push_back(Value::ofChar(c));
  return newList(std::move(v));
}
BI(strOfChars) {
  UNUSED_VM;
  std::u32string s;
  for (const Value& c : listOf(a[0])) s.push_back(c.asChar());
  return newStr(std::move(s));
}
BI(strReverse) {
  UNUSED_VM;
  std::u32string s = S(a[0]);
  std::reverse(s.begin(), s.end());
  return newStr(std::move(s));
}
BI(quoteStr) {
  UNUSED_VM;
  std::u32string r = U"\"";
  for (char32_t c : S(a[0])) escapeInto(r, c, '"');
  r.push_back('"');
  return newStr(std::move(r));
}
Value padImpl(VM& vm, Value* a, bool left) {
  const auto& s = S(a[0]);
  int64_t w = a[1].asInt();
  if (w < 0) vm.panic("negative count");
  if (static_cast<uint64_t>(w) <= s.size()) return a[0];
  std::u32string pad(static_cast<size_t>(w) - s.size(), a[2].asChar());
  return newStr(left ? pad + s : s + pad);
}
BI(padLeft) { return padImpl(vm, a, true); }
BI(padRight) { return padImpl(vm, a, false); }

// --------------------------------------------------------------- lists

BI(listNew) { UNUSED_VM; (void)a; return newList(); }
BI(listLen) { UNUSED_VM; return mkInt(static_cast<int64_t>(listOf(a[0]).size())); }
BI(push) { UNUSED_VM; listOf(a[0]).push_back(a[1]); return Value(); }
BI(pop) {
  auto& l = listOf(a[0]);
  if (l.empty()) vm.panic("empty list");
  Value r = std::move(l.back());
  l.pop_back();
  return r;
}
BI(insert) {
  auto& l = listOf(a[0]);
  int64_t i = a[1].asInt();
  if (i < 0 || static_cast<uint64_t>(i) > l.size()) vm.panic("index out of bounds");
  l.insert(l.begin() + i, a[2]);
  return Value();
}
BI(removeAt) {
  auto& l = listOf(a[0]);
  int64_t i = a[1].asInt();
  if (i < 0 || static_cast<uint64_t>(i) >= l.size()) vm.panic("index out of bounds");
  Value r = std::move(l[static_cast<size_t>(i)]);
  l.erase(l.begin() + i);
  return r;
}
BI(clear) { UNUSED_VM; listOf(a[0]).clear(); return Value(); }
BI(listRepeat) {
  int64_t n = a[1].asInt();
  if (n < 0) vm.panic("negative count");
  return newList(std::vector<Value>(static_cast<size_t>(n), a[0]));
}
BI(listConcat) {
  UNUSED_VM;
  std::vector<Value> v = listOf(a[0]);
  const auto& b = listOf(a[1]);
  v.insert(v.end(), b.begin(), b.end());
  return newList(std::move(v));
}
BI(slice) {
  auto& l = listOf(a[0]);
  int64_t from = a[1].asInt(), to = a[2].asInt();
  if (from < 0 || from > to || static_cast<uint64_t>(to) > l.size()) vm.panic("index out of bounds");
  return newList(std::vector<Value>(l.begin() + from, l.begin() + to));
}
BI(listCopy) { UNUSED_VM; return newList(listOf(a[0])); }
BI(reverseList) {
  UNUSED_VM;
  std::vector<Value> v(listOf(a[0]).rbegin(), listOf(a[0]).rend());
  return newList(std::move(v));
}
BI(listFirst) {
  auto& l = listOf(a[0]);
  if (l.empty()) vm.panic("empty list");
  return l.front();
}
BI(listLast) {
  auto& l = listOf(a[0]);
  if (l.empty()) vm.panic("empty list");
  return l.back();
}
BI(listMap) {
  Value xs = a[0], f = a[1];
  auto& l = listOf(xs);
  std::vector<Value> out;
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    out.push_back(vm.call1(f, x));
  }
  return newList(std::move(out));
}
BI(listFilter) {
  Value xs = a[0], f = a[1];
  auto& l = listOf(xs);
  std::vector<Value> out;
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    if (vm.call1(f, x).asBool()) out.push_back(std::move(x));
  }
  return newList(std::move(out));
}
BI(listFold) {
  Value xs = a[0], acc = a[1], f = a[2];
  auto& l = listOf(xs);
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    acc = vm.call2(f, acc, x);
  }
  return acc;
}
BI(listAny) {
  Value xs = a[0], f = a[1];
  auto& l = listOf(xs);
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    if (vm.call1(f, x).asBool()) return mkBool(true);
  }
  return mkBool(false);
}
BI(listAll) {
  Value xs = a[0], f = a[1];
  auto& l = listOf(xs);
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    if (!vm.call1(f, x).asBool()) return mkBool(false);
  }
  return mkBool(true);
}
BI(listFind) {
  Value xs = a[0], f = a[1];
  auto& l = listOf(xs);
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    if (vm.call1(f, x).asBool()) return mkSome(std::move(x));
  }
  return mkNone();
}
BI(listFindIndex) {
  Value xs = a[0], f = a[1];
  auto& l = listOf(xs);
  for (size_t i = 0; i < l.size(); ++i) {
    Value x = l[i];
    if (vm.call1(f, x).asBool()) return mkInt(static_cast<int64_t>(i));
  }
  return mkInt(-1);
}
BI(listIndexOf) {
  UNUSED_VM;
  const auto& l = listOf(a[0]);
  for (size_t i = 0; i < l.size(); ++i)
    if (valuesEqual(l[i], a[1])) return mkInt(static_cast<int64_t>(i));
  return mkInt(-1);
}
BI(listContains) {
  UNUSED_VM;
  const auto& l = listOf(a[0]);
  for (const Value& v : l)
    if (valuesEqual(v, a[1])) return mkBool(true);
  return mkBool(false);
}
BI(listZip) {
  UNUSED_VM;
  const auto &x = listOf(a[0]), &y = listOf(a[1]);
  size_t n = std::min(x.size(), y.size());
  std::vector<Value> out;
  out.reserve(n);
  for (size_t i = 0; i < n; ++i) out.push_back(mkPair(x[i], y[i]));
  return newList(std::move(out));
}
BI(listFlatten) {
  UNUSED_VM;
  std::vector<Value> out;
  for (const Value& inner : listOf(a[0]))
    for (const Value& v : listOf(inner)) out.push_back(v);
  return newList(std::move(out));
}
BI(sortBy) {
  Value xs = a[0], cmp = a[1];
  std::vector<Value> src = listOf(xs);
  size_t n = src.size();
  if (n <= 1) return newList(std::move(src));
  std::vector<Value> dst(n);
  for (size_t width = 1; width < n; width *= 2) {
    for (size_t i = 0; i < n; i += 2 * width) {
      size_t lo = i, mid = std::min(i + width, n), hi = std::min(i + 2 * width, n);
      size_t x = lo, y = mid, k = lo;
      while (x < mid && y < hi) {
        if (vm.call2(cmp, src[x], src[y]).asInt() <= 0) dst[k++] = src[x++];
        else dst[k++] = src[y++];
      }
      while (x < mid) dst[k++] = src[x++];
      while (y < hi) dst[k++] = src[y++];
    }
    src.swap(dst);
  }
  return newList(std::move(src));
}

// ---------------------------------------------------------------- maps

BI(mapNew) { UNUSED_VM; (void)a; return newMap(); }
BI(mapLen) { UNUSED_VM; return mkInt(static_cast<int64_t>(mapOf(a[0]).size())); }
BI(mapHas) { UNUSED_VM; return mkBool(mapOf(a[0]).find(a[1]) != nullptr); }
BI(mapGet) {
  UNUSED_VM;
  Value* v = mapOf(a[0]).find(a[1]);
  return v ? mkSome(*v) : mkNone();
}
BI(mapGetOr) {
  UNUSED_VM;
  Value* v = mapOf(a[0]).find(a[1]);
  return v ? *v : a[2];
}
BI(mapSet) { UNUSED_VM; mapOf(a[0]).set(a[1], a[2]); return Value(); }
BI(mapDel) { UNUSED_VM; return mkBool(mapOf(a[0]).erase(a[1])); }
BI(keysOf) {
  UNUSED_VM;
  std::vector<Value> out;
  for (auto& e : mapOf(a[0]).entries)
    if (e.live) out.push_back(e.k);
  return newList(std::move(out));
}
BI(valuesOf) {
  UNUSED_VM;
  std::vector<Value> out;
  for (auto& e : mapOf(a[0]).entries)
    if (e.live) out.push_back(e.v);
  return newList(std::move(out));
}
BI(pairsOf) {
  UNUSED_VM;
  std::vector<Value> out;
  for (auto& e : mapOf(a[0]).entries)
    if (e.live) out.push_back(mkPair(e.k, e.v));
  return newList(std::move(out));
}
BI(mapClear) { UNUSED_VM; mapOf(a[0]).clear(); return Value(); }
BI(mapCopy) {
  UNUSED_VM;
  Value m = newMap();
  for (auto& e : mapOf(a[0]).entries)
    if (e.live) mapOf(m).set(e.k, e.v);
  return m;
}

// ------------------------------------------------- option / result / tuples

BI(isSome) { UNUSED_VM; return mkBool(a[0].variant == 0); }
BI(isNone) { UNUSED_VM; return mkBool(a[0].variant == 1); }
BI(unwrap) {
  if (a[0].variant == 1) vm.panic("unwrap of None");
  return arrOf(a[0]).items()[0];
}
BI(unwrapOr) {
  UNUSED_VM;
  return a[0].variant == 1 ? a[1] : arrOf(a[0]).items()[0];
}
BI(isOk) { UNUSED_VM; return mkBool(a[0].variant == 0); }
BI(isErr) { UNUSED_VM; return mkBool(a[0].variant == 1); }
BI(unwrapOk) {
  if (a[0].variant == 1) vm.panic("unwrap of Err");
  return arrOf(a[0]).items()[0];
}
BI(unwrapErr) {
  if (a[0].variant == 0) vm.panic("unwrap of Ok");
  return arrOf(a[0]).items()[0];
}
BI(fst) { UNUSED_VM; return arrOf(a[0]).items()[0]; }
BI(snd) { UNUSED_VM; return arrOf(a[0]).items()[1]; }

BI(fmt) {
  const auto& t = S(a[0]);
  const auto& args = listOf(a[1]);
  std::u32string out;
  size_t used = 0;
  for (size_t i = 0; i < t.size(); ++i) {
    char32_t c = t[i];
    if (c == '{') {
      if (i + 1 >= t.size()) vm.panic("bad format");
      if (t[i + 1] == '{') {
        out.push_back('{');
        ++i;
      } else if (t[i + 1] == '}') {
        if (used < args.size()) out += S(args[used]);
        ++used;
        ++i;
      } else {
        vm.panic("bad format");
      }
    } else if (c == '}') {
      if (i + 1 < t.size() && t[i + 1] == '}') {
        out.push_back('}');
        ++i;
      } else {
        vm.panic("bad format");
      }
    } else {
      out.push_back(c);
    }
  }
  if (used != args.size()) vm.panic("bad format");
  return newStr(std::move(out));
}

#define E(name) {#name, bi_##name}
const BuiltinDef kBuiltins[] = {
    E(print), E(emit), E(panic),
    E(intMin), E(intMax), E(absI), E(minI), E(maxI), E(signI), E(cmpI), E(divFloor), E(modFloor), E(powI),
    E(gcdI), E(popCount), E(clz), E(ctz), E(toFloat), E(showInt), E(showIntRadix), E(parseInt),
    E(parseIntRadix),
    E(sqrtF), E(absF), E(floorF), E(ceilF), E(truncF), E(roundF), E(minF), E(maxF), E(fmodF), E(powF),
    E(isNanF), E(isInfF), E(cmpF), E(truncToInt), E(showFloat), E(showFloatAt), E(floatBits),
    E(floatFromBits), E(parseFloat), E(infF), E(nanF), E(piF),
    E(showBool), E(ord), E(chr), E(isDigit), E(isAlpha), E(isAlnum), E(isSpace), E(isUpper), E(isLower),
    E(toUpperC), E(toLowerC), E(cmpC), E(showChar), E(quoteChar),
    E(strLen), E(charAt), E(substr), E(strCat), E(strRepeat), E(strIndexOf), E(strLastIndexOf),
    E(strContains), E(startsWith), E(endsWith), E(strSplit), E(strJoin), E(strReplace), E(trim),
    E(trimLeft), E(trimRight), E(upper), E(lower), E(strCmp), E(chars), E(strOfChars), E(strReverse),
    E(quoteStr), E(padLeft), E(padRight),
    E(listNew), E(listLen), E(push), E(pop), E(insert), E(removeAt), E(clear), E(listRepeat),
    E(listConcat), E(slice), E(listCopy), E(reverseList), E(listFirst), E(listLast), E(listMap),
    E(listFilter), E(listFold), E(listAny), E(listAll), E(listFind), E(listFindIndex), E(listIndexOf),
    E(listContains), E(listZip), E(listFlatten), E(sortBy),
    E(mapNew), E(mapLen), E(mapHas), E(mapGet), E(mapGetOr), E(mapSet), E(mapDel), E(keysOf),
    E(valuesOf), E(pairsOf), E(mapClear), E(mapCopy),
    E(isSome), E(isNone), E(unwrap), E(unwrapOr), E(isOk), E(isErr), E(unwrapOk), E(unwrapErr), E(fst),
    E(snd), E(fmt),
};
#undef E

}  // namespace

int builtinCount() { return static_cast<int>(sizeof(kBuiltins) / sizeof(kBuiltins[0])); }
const BuiltinDef& builtinAt(int index) { return kBuiltins[index]; }

int builtinIndex(const std::string& name) {
  static const std::unordered_map<std::string, int> index = [] {
    std::unordered_map<std::string, int> m;
    for (int i = 0; i < builtinCount(); ++i) m[kBuiltins[i].name] = i;
    return m;
  }();
  auto it = index.find(name);
  return it == index.end() ? -1 : it->second;
}

}  // namespace langvm
