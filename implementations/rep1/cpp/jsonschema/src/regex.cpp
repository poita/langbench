#include "jsonschema/regex.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <memory>
#include <utility>
#include <vector>

#include "jsonschema/utf8.hpp"

namespace jsonschema {

namespace {

constexpr char32_t kMaxCodePoint = 0x10FFFF;
constexpr int kInfinite = -1;
constexpr std::size_t kMaxProgramSize = 4'000'000;

using Range = std::pair<char32_t, char32_t>;
using RangeSet = std::vector<Range>;

void normalise(RangeSet& set) {
  std::sort(set.begin(), set.end());
  RangeSet out;
  for (const Range& r : set) {
    if (!out.empty() && r.first <= out.back().second + 1) {
      out.back().second = std::max(out.back().second, r.second);
    } else {
      out.push_back(r);
    }
  }
  set = std::move(out);
}

RangeSet complement(RangeSet set) {
  normalise(set);
  RangeSet out;
  char32_t next = 0;
  bool done = false;
  for (const Range& r : set) {
    if (r.first > next) out.emplace_back(next, r.first - 1);
    if (r.second >= kMaxCodePoint) {
      done = true;
      break;
    }
    next = r.second + 1;
  }
  if (!done) out.emplace_back(next, kMaxCodePoint);
  return out;
}

RangeSet class_escape_set(char c) {
  RangeSet base;
  switch (c) {
    case 'd':
    case 'D': base = {{'0', '9'}}; break;
    case 'w':
    case 'W': base = {{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}}; break;
    default:  // 's' / 'S'
      base = {{0x09, 0x0D}, {0x20, 0x20}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200A},
              {0x2028, 0x2029}, {0x202F, 0x202F}, {0x205F, 0x205F}, {0x3000, 0x3000}, {0xFEFF, 0xFEFF}};
  }
  if (c == 'D' || c == 'W' || c == 'S') return complement(base);
  return base;
}

bool is_word(char32_t c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}

// ---------------------------------------------------------------- AST

enum class AssertKind { Begin, End, WordBoundary, NotWordBoundary };

struct Ast {
  enum class Kind { Empty, Char, Any, Class, Cat, Alt, Repeat, Assert };
  Kind kind = Kind::Empty;
  char32_t ch = 0;
  std::size_t cls = 0;
  AssertKind assertion = AssertKind::Begin;
  int min = 0, max = 0;
  std::vector<std::unique_ptr<Ast>> kids;
};
using AstPtr = std::unique_ptr<Ast>;

AstPtr make(Ast::Kind k) {
  auto n = std::make_unique<Ast>();
  n->kind = k;
  return n;
}

}  // namespace

// ---------------------------------------------------------------- program

struct Regex::Program {
  enum class Op : std::uint8_t { Char, Any, Class, Split, Jmp, Assert, Match };
  struct Inst {
    Op op;
    AssertKind assertion = AssertKind::Begin;
    char32_t ch = 0;
    std::size_t x = 0, y = 0;  // Class: x = class index; Split/Jmp: targets
  };
  std::vector<Inst> insts;
  std::vector<RangeSet> classes;
};

namespace {

// ---------------------------------------------------------------- parser

class Parser {
 public:
  Parser(std::u32string pattern, Regex::Program& prog) : p_(std::move(pattern)), prog_(prog) {}

  AstPtr parse() {
    AstPtr ast = parse_alt();
    if (pos_ < p_.size()) fail("unmatched ')'");
    return ast;
  }

 private:
  [[noreturn]] void fail(const std::string& msg) const { throw RegexError("invalid regular expression: " + msg); }

  bool at_end() const { return pos_ >= p_.size(); }
  char32_t peek(std::size_t off = 0) const { return pos_ + off < p_.size() ? p_[pos_ + off] : 0; }
  bool has(std::size_t off = 0) const { return pos_ + off < p_.size(); }

  AstPtr parse_alt() {
    AstPtr first = parse_cat();
    if (!(has() && peek() == '|')) return first;
    AstPtr alt = make(Ast::Kind::Alt);
    alt->kids.push_back(std::move(first));
    while (has() && peek() == '|') {
      ++pos_;
      alt->kids.push_back(parse_cat());
    }
    return alt;
  }

  AstPtr parse_cat() {
    AstPtr cat = make(Ast::Kind::Cat);
    while (has() && peek() != '|' && peek() != ')') cat->kids.push_back(parse_quantified());
    if (cat->kids.size() == 1) return std::move(cat->kids[0]);
    return cat;
  }

  AstPtr parse_quantified() {
    AstPtr atom = parse_atom();
    int lo = 0, hi = 0;
    bool quantified = false;
    if (has()) {
      char32_t c = peek();
      if (c == '*') {
        lo = 0, hi = kInfinite, quantified = true, ++pos_;
      } else if (c == '+') {
        lo = 1, hi = kInfinite, quantified = true, ++pos_;
      } else if (c == '?') {
        lo = 0, hi = 1, quantified = true, ++pos_;
      } else if (c == '{') {
        quantified = try_brace(lo, hi);
      }
    }
    if (!quantified) return atom;
    if (has() && peek() == '?') ++pos_;  // lazy form: same language
    if (hi != kInfinite && lo > hi) fail("numbers out of order in {} quantifier");
    AstPtr rep = make(Ast::Kind::Repeat);
    rep->min = lo;
    rep->max = hi;
    rep->kids.push_back(std::move(atom));
    return rep;
  }

  // At '{': consumes a well-formed {n}, {n,} or {n,m} and returns true; otherwise consumes nothing.
  bool try_brace(int& lo, int& hi) {
    std::size_t k = pos_ + 1;
    auto number = [&](int& out) {
      std::size_t b = k;
      long long v = 0;
      while (k < p_.size() && p_[k] >= '0' && p_[k] <= '9') {
        v = std::min<long long>(v * 10 + (p_[k] - '0'), 100000);
        ++k;
      }
      out = static_cast<int>(v);
      return k > b;
    };
    int a = 0, b = 0;
    if (!number(a)) return false;
    if (k < p_.size() && p_[k] == '}') {
      lo = hi = a;
      pos_ = k + 1;
      return true;
    }
    if (k >= p_.size() || p_[k] != ',') return false;
    ++k;
    if (k < p_.size() && p_[k] == '}') {
      lo = a;
      hi = kInfinite;
      pos_ = k + 1;
      return true;
    }
    if (!number(b)) return false;
    if (k >= p_.size() || p_[k] != '}') return false;
    lo = a;
    hi = b;
    pos_ = k + 1;
    return true;
  }

  AstPtr char_node(char32_t c) {
    AstPtr n = make(Ast::Kind::Char);
    n->ch = c;
    return n;
  }

  AstPtr class_node(RangeSet set) {
    normalise(set);
    AstPtr n = make(Ast::Kind::Class);
    n->cls = prog_.classes.size();
    prog_.classes.push_back(std::move(set));
    return n;
  }

  AstPtr assert_node(AssertKind k) {
    AstPtr n = make(Ast::Kind::Assert);
    n->assertion = k;
    return n;
  }

  AstPtr parse_atom() {
    char32_t c = peek();
    switch (c) {
      case '(': {
        ++pos_;
        if (has() && peek() == '?') {
          if (peek(1) == ':') {
            pos_ += 2;
          } else {
            fail("unsupported group syntax");
          }
        }
        AstPtr inner = parse_alt();
        if (!has() || peek() != ')') fail("missing ')'");
        ++pos_;
        return inner;
      }
      case '[': return parse_class();
      case '.': ++pos_; return make(Ast::Kind::Any);
      case '^': ++pos_; return assert_node(AssertKind::Begin);
      case '$': ++pos_; return assert_node(AssertKind::End);
      case '\\': return parse_escape_atom();
      case '*':
      case '+':
      case '?': fail("nothing to repeat");
      default: ++pos_; return char_node(c);
    }
  }

  static int hex_val(char32_t c) {
    if (c >= '0' && c <= '9') return static_cast<int>(c - '0');
    if (c >= 'a' && c <= 'f') return static_cast<int>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return static_cast<int>(c - 'A' + 10);
    return -1;
  }

  // After a backslash at pos_-1: reads `n` hex digits. Returns -1 (consuming nothing) if not all are hex.
  long read_hex(std::size_t n) {
    long v = 0;
    for (std::size_t k = 0; k < n; ++k) {
      int h = has(k) ? hex_val(peek(k)) : -1;
      if (h < 0) return -1;
      v = v * 16 + h;
    }
    pos_ += n;
    return v;
  }

  // Parses a character escape (the backslash is already consumed, `c` is the escape letter at pos_).
  char32_t parse_char_escape(bool in_class) {
    char32_t c = peek();
    ++pos_;
    switch (c) {
      case 'n': return '\n';
      case 'r': return '\r';
      case 't': return '\t';
      case 'f': return '\f';
      case 'v': return '\v';
      case '0': return 0;
      case 'b': return in_class ? 8 : 'b';
      case 'x': {
        long v = read_hex(2);
        return v < 0 ? 'x' : static_cast<char32_t>(v);
      }
      case 'u': {
        long v = read_hex(4);
        if (v < 0) return 'u';
        char32_t cp = static_cast<char32_t>(v);
        if (cp >= 0xD800 && cp <= 0xDBFF && peek() == '\\' && peek(1) == 'u') {
          std::size_t save = pos_;
          pos_ += 2;
          long lo = read_hex(4);
          if (lo >= 0xDC00 && lo <= 0xDFFF) {
            return 0x10000 + ((cp - 0xD800) << 10) + (static_cast<char32_t>(lo) - 0xDC00);
          }
          pos_ = save;
        }
        return cp;
      }
      case 'c': {
        char32_t l = peek();
        if ((l >= 'a' && l <= 'z') || (l >= 'A' && l <= 'Z')) {
          ++pos_;
          return l % 32;
        }
        --pos_;  // treat the backslash as a literal and re-read 'c'
        return '\\';
      }
      default: return c;  // identity escape
    }
  }

  static bool is_class_escape(char32_t c) {
    return c == 'd' || c == 'D' || c == 'w' || c == 'W' || c == 's' || c == 'S';
  }

  AstPtr parse_escape_atom() {
    ++pos_;  // backslash
    if (at_end()) fail("pattern ends with a backslash");
    char32_t c = peek();
    if (is_class_escape(c)) {
      ++pos_;
      return class_node(class_escape_set(static_cast<char>(c)));
    }
    if (c == 'b') {
      ++pos_;
      return assert_node(AssertKind::WordBoundary);
    }
    if (c == 'B') {
      ++pos_;
      return assert_node(AssertKind::NotWordBoundary);
    }
    return char_node(parse_char_escape(false));
  }

  AstPtr parse_class() {
    ++pos_;  // '['
    bool negate = false;
    if (has() && peek() == '^') {
      negate = true;
      ++pos_;
    }
    RangeSet set;
    while (true) {
      if (at_end()) fail("missing ']'");
      if (peek() == ']') {
        ++pos_;
        break;
      }
      bool lo_is_set = false;
      char32_t lo = 0;
      class_atom(set, lo, lo_is_set);
      if (!lo_is_set && has() && peek() == '-' && has(1) && peek(1) != ']') {
        std::size_t save = pos_;
        ++pos_;
        RangeSet tmp;
        bool hi_is_set = false;
        char32_t hi = 0;
        class_atom(tmp, hi, hi_is_set);
        if (hi_is_set) {  // `a-\d`: the dash is literal
          set.emplace_back(lo, lo);
          set.emplace_back('-', '-');
          set.insert(set.end(), tmp.begin(), tmp.end());
        } else {
          if (lo > hi) fail("range out of order in character class");
          set.emplace_back(lo, hi);
        }
        (void)save;
      } else if (!lo_is_set) {
        set.emplace_back(lo, lo);
      }
    }
    normalise(set);
    if (negate) set = complement(std::move(set));
    return class_node(std::move(set));
  }

  // Reads one class atom. A class escape adds its set directly and sets is_set;
  // otherwise `ch` receives the single character.
  void class_atom(RangeSet& set, char32_t& ch, bool& is_set) {
    char32_t c = peek();
    ++pos_;
    if (c != '\\') {
      ch = c;
      return;
    }
    if (at_end()) fail("pattern ends with a backslash");
    char32_t e = peek();
    if (is_class_escape(e)) {
      ++pos_;
      RangeSet s = class_escape_set(static_cast<char>(e));
      set.insert(set.end(), s.begin(), s.end());
      is_set = true;
      return;
    }
    ch = parse_char_escape(true);
  }

  std::u32string p_;
  std::size_t pos_ = 0;
  Regex::Program& prog_;
};

// ---------------------------------------------------------------- code generation

class Emitter {
 public:
  using Op = Regex::Program::Op;
  using Inst = Regex::Program::Inst;

  explicit Emitter(Regex::Program& prog) : prog_(prog) {}

  void emit(const Ast& n) {
    if (prog_.insts.size() > kMaxProgramSize) throw RegexError("regular expression too large");
    switch (n.kind) {
      case Ast::Kind::Empty: break;
      case Ast::Kind::Char: add({Op::Char, AssertKind::Begin, n.ch, 0, 0}); break;
      case Ast::Kind::Any: add({Op::Any, AssertKind::Begin, 0, 0, 0}); break;
      case Ast::Kind::Class: add({Op::Class, AssertKind::Begin, 0, n.cls, 0}); break;
      case Ast::Kind::Assert: add({Op::Assert, n.assertion, 0, 0, 0}); break;
      case Ast::Kind::Cat:
        for (const auto& k : n.kids) emit(*k);
        break;
      case Ast::Kind::Alt: {
        std::vector<std::size_t> jumps;
        for (std::size_t i = 0; i + 1 < n.kids.size(); ++i) {
          std::size_t split = add({Op::Split, AssertKind::Begin, 0, 0, 0});
          prog_.insts[split].x = split + 1;
          emit(*n.kids[i]);
          jumps.push_back(add({Op::Jmp, AssertKind::Begin, 0, 0, 0}));
          prog_.insts[split].y = prog_.insts.size();
        }
        emit(*n.kids.back());
        for (std::size_t j : jumps) prog_.insts[j].x = prog_.insts.size();
        break;
      }
      case Ast::Kind::Repeat: {
        const Ast& body = *n.kids[0];
        for (int i = 0; i < n.min; ++i) emit(body);
        if (n.max == kInfinite) {
          std::size_t split = add({Op::Split, AssertKind::Begin, 0, 0, 0});
          prog_.insts[split].x = split + 1;
          emit(body);
          add({Op::Jmp, AssertKind::Begin, 0, split, 0});
          prog_.insts[split].y = prog_.insts.size();
        } else {
          std::vector<std::size_t> splits;
          for (int i = n.min; i < n.max; ++i) {
            std::size_t split = add({Op::Split, AssertKind::Begin, 0, 0, 0});
            prog_.insts[split].x = split + 1;
            splits.push_back(split);
            emit(body);
          }
          for (std::size_t s : splits) prog_.insts[s].y = prog_.insts.size();
        }
        break;
      }
    }
  }

  void finish() { add({Op::Match, AssertKind::Begin, 0, 0, 0}); }

 private:
  std::size_t add(Inst i) {
    prog_.insts.push_back(i);
    return prog_.insts.size() - 1;
  }
  Regex::Program& prog_;
};

bool class_contains(const RangeSet& set, char32_t c) {
  std::size_t lo = 0, hi = set.size();
  while (lo < hi) {
    std::size_t mid = (lo + hi) / 2;
    if (c < set[mid].first) {
      hi = mid;
    } else if (c > set[mid].second) {
      lo = mid + 1;
    } else {
      return true;
    }
  }
  return false;
}

bool is_line_terminator(char32_t c) { return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029; }

}  // namespace

// ---------------------------------------------------------------- public API

Regex Regex::compile(std::string_view pattern) {
  auto prog = std::make_shared<Program>();
  Parser parser(utf8::decode(pattern), *prog);
  AstPtr ast = parser.parse();
  Emitter emitter(*prog);
  emitter.emit(*ast);
  emitter.finish();
  Regex r;
  r.program_ = std::move(prog);
  return r;
}

bool Regex::search(std::string_view subject) const { return search(utf8::decode(subject)); }

bool Regex::search(const std::u32string& s) const {
  using Op = Program::Op;
  const Program& prog = *program_;
  const std::size_t n = s.size();
  const std::size_t psize = prog.insts.size();

  std::vector<std::uint32_t> mark(psize, 0);
  std::vector<std::size_t> clist, nlist, stack;
  clist.reserve(psize);
  nlist.reserve(psize);
  bool matched = false;

  // Adds the epsilon closure of `start` at subject position `pos` to `list`.
  auto add = [&](std::vector<std::size_t>& list, std::size_t start, std::size_t pos, std::uint32_t gen) {
    stack.push_back(start);
    while (!stack.empty()) {
      std::size_t pc = stack.back();
      stack.pop_back();
      if (mark[pc] == gen) continue;
      mark[pc] = gen;
      const auto& in = prog.insts[pc];
      switch (in.op) {
        case Op::Jmp: stack.push_back(in.x); break;
        case Op::Split:
          stack.push_back(in.y);
          stack.push_back(in.x);
          break;
        case Op::Assert: {
          bool ok = false;
          switch (in.assertion) {
            case AssertKind::Begin: ok = pos == 0; break;
            case AssertKind::End: ok = pos == n; break;
            case AssertKind::WordBoundary:
            case AssertKind::NotWordBoundary: {
              bool before = pos > 0 && is_word(s[pos - 1]);
              bool after = pos < n && is_word(s[pos]);
              ok = (before != after) == (in.assertion == AssertKind::WordBoundary);
              break;
            }
          }
          if (ok) stack.push_back(pc + 1);
          break;
        }
        case Op::Match: matched = true; break;
        default: list.push_back(pc);
      }
    }
  };

  for (std::size_t pos = 0; pos <= n; ++pos) {
    const std::uint32_t gen = static_cast<std::uint32_t>(pos) + 1;
    add(clist, 0, pos, gen);  // a new match attempt starting here
    if (matched) return true;
    if (pos == n) break;
    const char32_t c = s[pos];
    nlist.clear();
    for (std::size_t pc : clist) {
      const auto& in = prog.insts[pc];
      bool ok = false;
      switch (in.op) {
        case Op::Char: ok = in.ch == c; break;
        case Op::Any: ok = !is_line_terminator(c); break;
        case Op::Class: ok = class_contains(prog.classes[in.x], c); break;
        default: break;
      }
      if (ok) add(nlist, pc + 1, pos + 1, gen + 1);
    }
    clist.swap(nlist);
  }
  return false;
}

}  // namespace jsonschema
