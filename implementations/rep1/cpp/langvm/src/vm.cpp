#include "vm.h"

#include <cstring>

#include "builtins.h"
#include "utf8.h"

namespace langvm {
namespace {

constexpr size_t kMaxFrames = 20000;

template <class T>
bool compareWith(Op16 op, T x, T y) {
  switch (op) {
    case Op16::LT: return x < y;
    case Op16::LE: return x <= y;
    case Op16::GT: return x > y;
    default: return x >= y;
  }
}

bool compareValues(Op16 op, const Value& a, const Value& b) {
  switch (a.t) {
    case VT::Float: return compareWith<double>(op, a.u.f, b.u.f);
    case VT::Str: return compareWith<int>(op, strOf(a).compare(strOf(b)), 0);
    default: return compareWith<int64_t>(op, a.u.i, b.u.i);
  }
}

inline int64_t wrapAdd(int64_t a, int64_t b) { return static_cast<int64_t>(static_cast<uint64_t>(a) + static_cast<uint64_t>(b)); }
inline int64_t wrapSub(int64_t a, int64_t b) { return static_cast<int64_t>(static_cast<uint64_t>(a) - static_cast<uint64_t>(b)); }
inline int64_t wrapMul(int64_t a, int64_t b) { return static_cast<int64_t>(static_cast<uint64_t>(a) * static_cast<uint64_t>(b)); }

}  // namespace

VM::VM(const Program::Impl& program, std::ostream& out) : prog_(program), out_(out) {
  cap_ = 1 << 16;
  stack_ = static_cast<Value*>(std::calloc(cap_, sizeof(Value)));
  frames_.reserve(1024);
}

VM::~VM() {
  truncate(0);
  std::free(stack_);
}

void VM::flush() {
  if (!outBuf_.empty()) {
    out_.write(outBuf_.data(), static_cast<std::streamsize>(outBuf_.size()));
    outBuf_.clear();
  }
}

void VM::write(const std::u32string& s) {
  for (char32_t c : s) appendUtf8(outBuf_, c);
  if (outBuf_.size() > (1u << 16)) flush();
}

void VM::panic(const std::string& message) { throw Panic{message}; }

void VM::reserve(size_t needed) {
  if (needed <= cap_) return;
  size_t ncap = std::max(needed, cap_ * 2);
  stack_ = static_cast<Value*>(std::realloc(stack_, ncap * sizeof(Value)));
  std::memset(static_cast<void*>(stack_ + cap_), 0, (ncap - cap_) * sizeof(Value));
  cap_ = ncap;
}

void VM::truncate(size_t newSp) {
  while (sp_ > newSp) {
    --sp_;
    if (stack_[sp_].isRef()) stack_[sp_] = Value();
  }
}

void VM::pushFrame(int func, size_t base, size_t retBase, const Value* closure) {
  if (frames_.size() >= kMaxFrames) panic("call stack overflow");
  const CompiledFunction& f = prog_.funcs[static_cast<size_t>(func)];
  reserve(base + static_cast<size_t>(f.nlocals) + static_cast<size_t>(f.maxStack) + 32);
  sp_ = base + static_cast<size_t>(f.nlocals);
  frames_.push_back({&f, 0, base, retBase, closure ? *closure : Value()});
}

Value VM::callValue(const Value& f, const Value* args, int n) {
  reserve(sp_ + static_cast<size_t>(n) + 8);
  Value clo = f;
  stack_[sp_++] = clo;
  for (int i = 0; i < n; ++i) stack_[sp_++] = args[i];
  size_t base = sp_ - static_cast<size_t>(n);
  size_t depth = frames_.size();
  pushFrame(arrOf(clo).aux, base, base - 1, &clo);
  return execute(depth);
}

RunResult VM::run() {
  RunResult res;
  try {
    pushFrame(prog_.mainFunc, 0, 0, nullptr);
    execute(0);
  } catch (const Panic& p) {
    res.panicked = true;
    res.panicMessage = p.message;
    outBuf_ += "panic: " + p.message + "\n";
  }
  flush();
  out_.flush();
  return res;
}

#define PUSH(expr) (stack_[sp_++] = (expr))
#define TOP() (stack_[sp_ - 1])
#define RELOAD()                         \
  do {                                   \
    fr = &frames_.back();                \
    code = fr->fn->code.data();          \
    locals = stack_ + fr->base;          \
  } while (0)

Value VM::execute(size_t stopDepth) {
  Frame* fr;
  const Instr* code;
  Value* locals;
  size_t pc = 0;
  RELOAD();

  for (;;) {
    const Instr& in = code[pc++];
    switch (in.op) {
      case Op16::PUSH_CONST: PUSH(prog_.consts[static_cast<size_t>(in.a)]); break;
      case Op16::PUSH_TRUE: PUSH(Value::ofBool(true)); break;
      case Op16::PUSH_FALSE: PUSH(Value::ofBool(false)); break;
      case Op16::PUSH_UNIT: PUSH(Value()); break;
      case Op16::LOAD_LOCAL: PUSH(locals[in.a]); break;
      case Op16::STORE_LOCAL: locals[in.a] = std::move(stack_[--sp_]); break;
      case Op16::LOAD_UPVAL: PUSH(arrOf(fr->closure).items()[in.a]); break;
      case Op16::POP: --sp_; if (stack_[sp_].isRef()) stack_[sp_] = Value(); break;
      case Op16::POPN: truncate(sp_ - static_cast<size_t>(in.a)); break;

      case Op16::MAKE_CLOSURE: {
        size_t n = static_cast<size_t>(in.b);
        Value clo = newArr(VT::Closure, static_cast<uint32_t>(n), 0, 0, in.a);
        Value* items = arrOf(clo).items();
        for (size_t i = 0; i < n; ++i) items[i] = std::move(stack_[sp_ - n + i]);
        sp_ -= n;
        PUSH(std::move(clo));
        break;
      }
      case Op16::CALL: {
        fr->pc = pc;
        size_t base = sp_ - in.c;
        pushFrame(in.a, base, base, nullptr);
        RELOAD();
        pc = 0;
        break;
      }
      case Op16::CALL_VALUE: {
        fr->pc = pc;
        size_t base = sp_ - in.c;
        Value clo = stack_[base - 1];
        pushFrame(arrOf(clo).aux, base, base - 1, &clo);
        RELOAD();
        pc = 0;
        break;
      }
      case Op16::CALL_METHOD: {
        fr->pc = pc;
        size_t base = sp_ - in.c - 1;
        int ctor = valueCtor(stack_[base]);
        auto it = prog_.impls.find((static_cast<unsigned long long>(in.a) << 32) | static_cast<unsigned>(ctor));
        pushFrame(it->second[static_cast<size_t>(in.b)], base, base, nullptr);
        RELOAD();
        pc = 0;
        break;
      }
      case Op16::CALL_BUILTIN: {
        size_t base = sp_ - in.c;
        Value r = builtinAt(in.a).fn(*this, stack_ + base);
        truncate(base);
        PUSH(std::move(r));
        RELOAD();
        break;
      }
      case Op16::RET:
      case Op16::RET_UNIT: {
        Value r;
        if (in.op == Op16::RET) r = std::move(stack_[--sp_]);
        truncate(fr->retBase);
        frames_.pop_back();
        if (frames_.size() == stopDepth) return r;
        PUSH(std::move(r));
        RELOAD();
        pc = fr->pc;
        break;
      }

      case Op16::ADD_I: { int64_t b = stack_[--sp_].u.i; TOP().u.i = wrapAdd(TOP().u.i, b); break; }
      case Op16::SUB_I: { int64_t b = stack_[--sp_].u.i; TOP().u.i = wrapSub(TOP().u.i, b); break; }
      case Op16::MUL_I: { int64_t b = stack_[--sp_].u.i; TOP().u.i = wrapMul(TOP().u.i, b); break; }
      case Op16::DIV_I: {
        int64_t b = stack_[--sp_].u.i;
        if (b == 0) panic("divide by zero");
        TOP().u.i = b == -1 ? wrapSub(0, TOP().u.i) : TOP().u.i / b;
        break;
      }
      case Op16::MOD_I: {
        int64_t b = stack_[--sp_].u.i;
        if (b == 0) panic("modulo by zero");
        TOP().u.i = b == -1 ? 0 : TOP().u.i % b;
        break;
      }
      case Op16::NEG_I: TOP().u.i = wrapSub(0, TOP().u.i); break;
      case Op16::BNOT: TOP().u.i = ~TOP().u.i; break;
      case Op16::BAND: { int64_t b = stack_[--sp_].u.i; TOP().u.i &= b; break; }
      case Op16::BOR: { int64_t b = stack_[--sp_].u.i; TOP().u.i |= b; break; }
      case Op16::BXOR: { int64_t b = stack_[--sp_].u.i; TOP().u.i ^= b; break; }
      case Op16::SHL: {
        int64_t b = stack_[--sp_].u.i;
        if (b < 0 || b > 63) panic("shift amount out of range");
        TOP().u.i = static_cast<int64_t>(static_cast<uint64_t>(TOP().u.i) << b);
        break;
      }
      case Op16::SHR: {
        int64_t b = stack_[--sp_].u.i;
        if (b < 0 || b > 63) panic("shift amount out of range");
        TOP().u.i >>= b;
        break;
      }
      case Op16::ADD_F: { double b = stack_[--sp_].u.f; TOP().u.f = TOP().u.f + b; break; }
      case Op16::SUB_F: { double b = stack_[--sp_].u.f; TOP().u.f = TOP().u.f - b; break; }
      case Op16::MUL_F: { double b = stack_[--sp_].u.f; TOP().u.f = TOP().u.f * b; break; }
      case Op16::DIV_F: { double b = stack_[--sp_].u.f; TOP().u.f = TOP().u.f / b; break; }
      case Op16::NEG_F: TOP().u.f = -TOP().u.f; break;
      case Op16::NOT_B: TOP().u.i = !TOP().u.i; break;

      case Op16::EQ: case Op16::NE: {
        Value b = std::move(stack_[--sp_]);
        bool eq = valuesEqual(TOP(), b);
        TOP() = Value::ofBool(in.op == Op16::EQ ? eq : !eq);
        break;
      }
      case Op16::LT: case Op16::LE: case Op16::GT: case Op16::GE: {
        Value b = std::move(stack_[--sp_]);
        bool r = compareValues(in.op, TOP(), b);
        TOP() = Value::ofBool(r);
        break;
      }
      case Op16::CONCAT: {
        Value b = std::move(stack_[--sp_]);
        Value& a = TOP();
        if (a.t == VT::Str) {
          std::u32string s;
          s.reserve(strOf(a).size() + strOf(b).size());
          s += strOf(a);
          s += strOf(b);
          a = newStr(std::move(s));
        } else {
          std::vector<Value> v;
          v.reserve(listOf(a).size() + listOf(b).size());
          for (const Value& x : listOf(a)) v.push_back(x);
          for (const Value& x : listOf(b)) v.push_back(x);
          a = newList(std::move(v));
        }
        break;
      }

      case Op16::JUMP: pc = static_cast<size_t>(in.a); break;
      case Op16::JUMP_IF_FALSE: if (!stack_[--sp_].u.i) pc = static_cast<size_t>(in.a); break;
      case Op16::JUMP_IF_TRUE: if (stack_[--sp_].u.i) pc = static_cast<size_t>(in.a); break;

      case Op16::MAKE_LIST: {
        size_t n = static_cast<size_t>(in.a);
        std::vector<Value> v;
        v.reserve(n);
        for (size_t i = 0; i < n; ++i) v.push_back(std::move(stack_[sp_ - n + i]));
        sp_ -= n;
        PUSH(newList(std::move(v)));
        break;
      }
      case Op16::MAKE_MAP: {
        size_t n = static_cast<size_t>(in.a);
        Value m = newMap();
        MapObj& mo = mapOf(m);
        for (size_t i = 0; i < n; ++i) mo.set(stack_[sp_ - 2 * n + 2 * i], stack_[sp_ - 2 * n + 2 * i + 1]);
        truncate(sp_ - 2 * n);
        PUSH(std::move(m));
        break;
      }
      case Op16::MAKE_TUPLE: case Op16::MAKE_STRUCT: case Op16::MAKE_ENUM: {
        size_t n = in.op == Op16::MAKE_STRUCT ? static_cast<size_t>(in.b)
                   : in.op == Op16::MAKE_ENUM ? in.c : static_cast<size_t>(in.a);
        VT kind = in.op == Op16::MAKE_TUPLE ? VT::Tuple : in.op == Op16::MAKE_STRUCT ? VT::Struct : VT::Enum;
        uint32_t decl = in.op == Op16::MAKE_TUPLE ? 0 : static_cast<uint32_t>(in.a);
        uint8_t variant = in.op == Op16::MAKE_ENUM ? static_cast<uint8_t>(in.b) : 0;
        if (kind == VT::Enum && n == 0) {
          Value v;
          v.t = VT::Enum;
          v.decl = decl;
          v.variant = variant;
          v.u.o = nullptr;
          PUSH(std::move(v));
          break;
        }
        Value v = newArr(kind, static_cast<uint32_t>(n), decl, variant);
        Value* items = arrOf(v).items();
        for (size_t i = 0; i < n; ++i) items[i] = std::move(stack_[sp_ - n + i]);
        sp_ -= n;
        PUSH(std::move(v));
        break;
      }
      case Op16::GET_FIELD: case Op16::GET_PAYLOAD: case Op16::GET_TUPLE: {
        Value v = arrOf(TOP()).items()[in.a];
        TOP() = std::move(v);
        break;
      }
      case Op16::INDEX_GET: {
        Value idx = std::move(stack_[--sp_]);
        Value& c = TOP();
        if (c.t == VT::List) {
          auto& l = listOf(c);
          if (idx.u.i < 0 || static_cast<uint64_t>(idx.u.i) >= l.size()) panic("index out of bounds");
          Value r = l[static_cast<size_t>(idx.u.i)];
          c = std::move(r);
        } else if (c.t == VT::Str) {
          const auto& s = strOf(c);
          if (idx.u.i < 0 || static_cast<uint64_t>(idx.u.i) >= s.size()) panic("index out of bounds");
          Value r = Value::ofChar(s[static_cast<size_t>(idx.u.i)]);
          c = std::move(r);
        } else {
          Value* f = mapOf(c).find(idx);
          if (!f) panic("missing key");
          Value r = *f;
          c = std::move(r);
        }
        break;
      }
      case Op16::INDEX_SET: {
        Value val = std::move(stack_[--sp_]);
        Value idx = std::move(stack_[--sp_]);
        Value c = std::move(stack_[--sp_]);
        if (c.t == VT::List) {
          auto& l = listOf(c);
          if (idx.u.i < 0 || static_cast<uint64_t>(idx.u.i) >= l.size()) panic("index out of bounds");
          l[static_cast<size_t>(idx.u.i)] = std::move(val);
        } else {
          mapOf(c).set(idx, val);
        }
        break;
      }
      case Op16::IS_VARIANT: TOP() = Value::ofBool(TOP().variant == in.a); break;
      case Op16::SEQ_LEN: {
        int64_t n = TOP().t == VT::Str ? static_cast<int64_t>(strOf(TOP()).size())
                                       : static_cast<int64_t>(listOf(TOP()).size());
        TOP() = Value::ofInt(n);
        break;
      }
      case Op16::LIST_REST: {
        const auto& l = listOf(TOP());
        std::vector<Value> v(l.begin() + std::min<size_t>(static_cast<size_t>(in.a), l.size()), l.end());
        Value r = newList(std::move(v));
        TOP() = std::move(r);
        break;
      }
      case Op16::NO_MATCH: panic("no match");
      case Op16::HALT: return Value();
    }
  }
}

}  // namespace langvm
