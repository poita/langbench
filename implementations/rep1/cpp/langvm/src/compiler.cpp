#include "compiler.h"

#include <cstring>
#include <functional>

namespace langvm {
namespace {

class Compiler {
 public:
  explicit Compiler(Model& m) : m_(m) {}

  std::unique_ptr<Program::Impl> run() {
    out_ = std::make_unique<Program::Impl>();
    out_->funcs.resize(m_.funcs.size());
    for (size_t i = 0; i < m_.funcs.size(); ++i) {
      FuncInfo& fi = m_.funcs[i];
      if (fi.kind == FuncInfo::Kind::Builtin || !fi.ast || !fi.ast->body) continue;
      compileFunction(static_cast<int>(i), fi);
    }
    for (const ImplInfo& im : m_.impls) out_->impls[Model::implKey(im.trait, im.ctor)] = im.byTraitMethod;
    out_->mainFunc = m_.mainFunc;
    return std::move(out_);
  }

 private:
  Model& m_;
  std::unique_ptr<Program::Impl> out_;

  struct Loop {
    int depth;
    std::vector<size_t> breaks, continues;
  };
  struct FnState {
    int index = 0;
    std::vector<Instr> code;
    int nextSlot = 0, maxSlot = 0;
    int depth = 0, maxDepth = 0;
    std::vector<Loop> loops;
    std::unordered_map<LocalVar*, int> upvals;
  };
  std::vector<FnState*> stack_;
  FnState& cur() { return *stack_.back(); }

  std::unordered_map<int64_t, int> intConsts_, charConsts_, floatConsts_;
  std::unordered_map<std::u32string, int> strConsts_;

  // ------------------------------------------------------------ emission

  static int effect(Op16 op, int a, int b, int c) {
    switch (op) {
      case Op16::PUSH_CONST: case Op16::PUSH_TRUE: case Op16::PUSH_FALSE: case Op16::PUSH_UNIT:
      case Op16::LOAD_LOCAL: case Op16::LOAD_UPVAL: return 1;
      case Op16::STORE_LOCAL: case Op16::POP: return -1;
      case Op16::POPN: return -a;
      case Op16::MAKE_CLOSURE: return 1 - b;
      case Op16::CALL: case Op16::CALL_BUILTIN: return 1 - c;
      case Op16::CALL_VALUE: case Op16::CALL_METHOD: return -c;
      case Op16::RET: return -1;
      case Op16::ADD_I: case Op16::SUB_I: case Op16::MUL_I: case Op16::DIV_I: case Op16::MOD_I:
      case Op16::BAND: case Op16::BOR: case Op16::BXOR: case Op16::SHL: case Op16::SHR:
      case Op16::ADD_F: case Op16::SUB_F: case Op16::MUL_F: case Op16::DIV_F:
      case Op16::EQ: case Op16::NE: case Op16::LT: case Op16::LE: case Op16::GT: case Op16::GE:
      case Op16::CONCAT: case Op16::INDEX_GET: return -1;
      case Op16::JUMP_IF_FALSE: case Op16::JUMP_IF_TRUE: return -1;
      case Op16::MAKE_LIST: case Op16::MAKE_TUPLE: return 1 - a;
      case Op16::MAKE_MAP: return 1 - 2 * a;
      case Op16::MAKE_STRUCT: return 1 - b;
      case Op16::MAKE_ENUM: return 1 - c;
      case Op16::INDEX_SET: return -3;
      default: return 0;
    }
  }

  size_t emit(Op16 op, int a = 0, int b = 0, int c = 0) {
    FnState& f = cur();
    f.code.push_back(Instr{op, static_cast<uint16_t>(c), a, b});
    f.depth += effect(op, a, b, c);
    f.maxDepth = std::max(f.maxDepth, f.depth);
    return f.code.size() - 1;
  }
  size_t here() { return cur().code.size(); }
  void patch(size_t at, size_t target) { cur().code[at].a = static_cast<int>(target); }
  void patchHere(const std::vector<size_t>& v) {
    for (size_t at : v) patch(at, here());
  }
  int allocSlot() {
    FnState& f = cur();
    int s = f.nextSlot++;
    f.maxSlot = std::max(f.maxSlot, f.nextSlot);
    return s;
  }

  int constInt(int64_t v) {
    auto it = intConsts_.find(v);
    if (it != intConsts_.end()) return it->second;
    out_->consts.push_back(Value::ofInt(v));
    return intConsts_[v] = static_cast<int>(out_->consts.size()) - 1;
  }
  int constChar(int64_t v) {
    auto it = charConsts_.find(v);
    if (it != charConsts_.end()) return it->second;
    out_->consts.push_back(Value::ofChar(static_cast<char32_t>(v)));
    return charConsts_[v] = static_cast<int>(out_->consts.size()) - 1;
  }
  int constFloat(double d) {
    int64_t bits;
    std::memcpy(&bits, &d, sizeof bits);
    auto it = floatConsts_.find(bits);
    if (it != floatConsts_.end()) return it->second;
    out_->consts.push_back(Value::ofFloat(d));
    return floatConsts_[bits] = static_cast<int>(out_->consts.size()) - 1;
  }
  int constStr(const std::u32string& s) {
    auto it = strConsts_.find(s);
    if (it != strConsts_.end()) return it->second;
    out_->consts.push_back(newStr(s));
    return strConsts_[s] = static_cast<int>(out_->consts.size()) - 1;
  }

  void loadVar(LocalVar* v) {
    auto it = cur().upvals.find(v);
    if (it != cur().upvals.end()) emit(Op16::LOAD_UPVAL, it->second);
    else emit(Op16::LOAD_LOCAL, v->slot);
  }

  // ----------------------------------------------------------- functions

  void finishFunction(FnState& st, const std::string& name, int nparams) {
    CompiledFunction& cf = out_->funcs[static_cast<size_t>(st.index)];
    cf.name = name;
    cf.nparams = nparams;
    cf.nlocals = st.maxSlot;
    cf.maxStack = st.maxDepth;
    cf.code = std::move(st.code);
  }

  void compileBody(Block& body) {
    for (auto& s : body.stmts) compileStmt(*s);
    if (body.tail) {
      compileExpr(*body.tail);
      emit(Op16::RET);
    } else {
      emit(Op16::RET_UNIT);
    }
  }

  void compileFunction(int id, FuncInfo& fi) {
    FnDecl& f = *fi.ast;
    FnState st;
    st.index = id;
    stack_.push_back(&st);
    int n = 0;
    if (f.hasSelf) f.selfVar->slot = n++;
    for (Param& p : f.params) p.var->slot = n++;
    st.nextSlot = st.maxSlot = n;
    compileBody(*f.body);
    stack_.pop_back();
    finishFunction(st, fi.name, n);
  }

  void compileLambda(Expr& e) {
    int idx = static_cast<int>(out_->funcs.size());
    out_->funcs.emplace_back();
    FnState st;
    st.index = idx;
    for (size_t i = 0; i < e.captures.size(); ++i) st.upvals[e.captures[i]] = static_cast<int>(i);
    stack_.push_back(&st);
    int n = 0;
    for (LParam& p : e.lparams) p.var->slot = n++;
    st.nextSlot = st.maxSlot = n;
    compileBody(*e.body);
    stack_.pop_back();
    finishFunction(st, "<lambda>", n);
    for (LocalVar* v : e.captures) loadVar(v);
    emit(Op16::MAKE_CLOSURE, idx, static_cast<int>(e.captures.size()));
  }

  // ---------------------------------------------------------- statements

  struct SlotScope {
    Compiler& c;
    int mark;
    explicit SlotScope(Compiler& cc) : c(cc), mark(cc.cur().nextSlot) {}
    ~SlotScope() { c.cur().nextSlot = mark; }
  };

  void compileBlockValue(Block& b) {
    SlotScope sc(*this);
    for (auto& s : b.stmts) compileStmt(*s);
    if (b.tail) compileExpr(*b.tail);
    else emit(Op16::PUSH_UNIT);
  }

  void compileStmtBlock(Block& b) {
    SlotScope sc(*this);
    for (auto& s : b.stmts) compileStmt(*s);
    if (b.tail) {
      compileExpr(*b.tail);
      emit(Op16::POP);
    }
  }

  void bindPatternFromStack(Pattern& p) {
    if (p.kind == Pattern::K::Bind) {
      p.var->slot = allocSlot();
      emit(Op16::STORE_LOCAL, p.var->slot);
      return;
    }
    int tmp = allocSlot();
    emit(Op16::STORE_LOCAL, tmp);
    std::vector<size_t> fails;
    compilePattern(p, tmp, fails);
    if (!fails.empty()) {
      size_t skip = emit(Op16::JUMP);
      patchHere(fails);
      emit(Op16::NO_MATCH);
      patch(skip, here());
    }
  }

  void compileStmt(Stmt& s) {
    switch (s.kind) {
      case Stmt::K::Let:
        compileExpr(*s.expr);
        bindPatternFromStack(*s.pat);
        break;
      case Stmt::K::Var:
        compileExpr(*s.expr);
        s.var->slot = allocSlot();
        emit(Op16::STORE_LOCAL, s.var->slot);
        break;
      case Stmt::K::Assign: {
        Expr& t = *s.expr;
        if (t.kind == EK::Path) {
          compileExpr(*s.expr2);
          emit(Op16::STORE_LOCAL, t.var->slot);
        } else {
          compileExpr(*t.lhs);
          compileExpr(*t.rhs);
          compileExpr(*s.expr2);
          emit(Op16::INDEX_SET);
        }
        break;
      }
      case Stmt::K::Expr:
        compileExpr(*s.expr);
        emit(Op16::POP);
        break;
      case Stmt::K::Return:
        if (s.expr) {
          compileExpr(*s.expr);
          emit(Op16::RET);
        } else {
          emit(Op16::RET_UNIT);
        }
        break;
      case Stmt::K::While: {
        size_t start = here();
        compileExpr(*s.expr);
        size_t exit = emit(Op16::JUMP_IF_FALSE);
        cur().loops.push_back({cur().depth, {}, {}});
        compileStmtBlock(*s.body);
        Loop loop = std::move(cur().loops.back());
        cur().loops.pop_back();
        for (size_t at : loop.continues) patch(at, start);
        emit(Op16::JUMP, static_cast<int>(start));
        patch(exit, here());
        patchHere(loop.breaks);
        break;
      }
      case Stmt::K::For: compileFor(s); break;
      case Stmt::K::Break: case Stmt::K::Continue: {
        Loop& loop = cur().loops.back();
        int saved = cur().depth;
        if (saved > loop.depth) emit(Op16::POPN, saved - loop.depth);
        size_t j = emit(Op16::JUMP);
        (s.kind == Stmt::K::Break ? loop.breaks : loop.continues).push_back(j);
        cur().depth = saved;
        break;
      }
    }
  }

  void compileFor(Stmt& s) {
    SlotScope sc(*this);
    int idx = allocSlot();
    int limit = allocSlot();  // list/string (sequence form) or upper bound (range form)
    if (s.isRange) {
      compileExpr(*s.expr);
      compileExpr(*s.expr2);
      emit(Op16::STORE_LOCAL, limit);
      emit(Op16::STORE_LOCAL, idx);
    } else {
      compileExpr(*s.expr);
      emit(Op16::STORE_LOCAL, limit);
      emit(Op16::PUSH_CONST, constInt(0));
      emit(Op16::STORE_LOCAL, idx);
    }
    size_t start = here();
    emit(Op16::LOAD_LOCAL, idx);
    emit(Op16::LOAD_LOCAL, limit);
    if (!s.isRange) emit(Op16::SEQ_LEN);
    emit(Op16::LT);
    size_t exit = emit(Op16::JUMP_IF_FALSE);
    {
      SlotScope inner(*this);
      if (s.isRange) {
        std::vector<size_t> fails;
        compilePattern(*s.pat, idx, fails);
      } else {
        emit(Op16::LOAD_LOCAL, limit);
        emit(Op16::LOAD_LOCAL, idx);
        emit(Op16::INDEX_GET);
        bindPatternFromStack(*s.pat);
      }
      cur().loops.push_back({cur().depth, {}, {}});
      compileStmtBlock(*s.body);
    }
    Loop loop = std::move(cur().loops.back());
    cur().loops.pop_back();
    patchHere(loop.continues);
    emit(Op16::LOAD_LOCAL, idx);
    emit(Op16::PUSH_CONST, constInt(1));
    emit(Op16::ADD_I);
    emit(Op16::STORE_LOCAL, idx);
    emit(Op16::JUMP, static_cast<int>(start));
    patch(exit, here());
    patchHere(loop.breaks);
  }

  // ------------------------------------------------------------ patterns

  // Emits code testing / destructuring the value in `slot` against `p`; a failed
  // test jumps to a position recorded in `fails`.
  void compilePattern(Pattern& p, int slot, std::vector<size_t>& fails) {
    auto literal = [&](int constIdx) {
      emit(Op16::LOAD_LOCAL, slot);
      emit(Op16::PUSH_CONST, constIdx);
      emit(Op16::EQ);
      fails.push_back(emit(Op16::JUMP_IF_FALSE));
    };
    // Extracts a component (via `extract`) and matches it against `sub`.
    auto sub = [&](Pattern& sp, const std::function<void()>& extract) {
      if (sp.kind == Pattern::K::Wild) return;
      extract();
      if (sp.kind == Pattern::K::Bind) {
        sp.var->slot = allocSlot();
        emit(Op16::STORE_LOCAL, sp.var->slot);
        return;
      }
      int tmp = allocSlot();
      emit(Op16::STORE_LOCAL, tmp);
      compilePattern(sp, tmp, fails);
    };
    switch (p.kind) {
      case Pattern::K::Wild: break;
      case Pattern::K::Bind:
        emit(Op16::LOAD_LOCAL, slot);
        p.var->slot = allocSlot();
        emit(Op16::STORE_LOCAL, p.var->slot);
        break;
      case Pattern::K::Int: literal(constInt(p.ival)); break;
      case Pattern::K::Char: literal(constChar(p.ival)); break;
      case Pattern::K::Str: literal(constStr(p.sval)); break;
      case Pattern::K::Bool:
        emit(Op16::LOAD_LOCAL, slot);
        emit(p.bval ? Op16::PUSH_TRUE : Op16::PUSH_FALSE);
        emit(Op16::EQ);
        fails.push_back(emit(Op16::JUMP_IF_FALSE));
        break;
      case Pattern::K::Tuple:
        for (size_t i = 0; i < p.subs.size(); ++i)
          sub(*p.subs[i], [&, i] {
            emit(Op16::LOAD_LOCAL, slot);
            emit(Op16::GET_TUPLE, static_cast<int>(i));
          });
        break;
      case Pattern::K::Struct:
        for (FieldPat& f : p.fields)
          sub(*f.pat, [&, idx = f.fieldIdx] {
            emit(Op16::LOAD_LOCAL, slot);
            emit(Op16::GET_FIELD, idx);
          });
        break;
      case Pattern::K::Path:
        if (m_.decls[static_cast<size_t>(p.decl)].variants.size() > 1) {
          emit(Op16::LOAD_LOCAL, slot);
          emit(Op16::IS_VARIANT, p.variant);
          fails.push_back(emit(Op16::JUMP_IF_FALSE));
        }
        for (size_t i = 0; i < p.subs.size(); ++i)
          sub(*p.subs[i], [&, i] {
            emit(Op16::LOAD_LOCAL, slot);
            emit(Op16::GET_PAYLOAD, static_cast<int>(i));
          });
        break;
      case Pattern::K::List: {
        int n = static_cast<int>(p.subs.size());
        emit(Op16::LOAD_LOCAL, slot);
        emit(Op16::SEQ_LEN);
        emit(Op16::PUSH_CONST, constInt(n));
        emit(p.hasRest ? Op16::GE : Op16::EQ);
        fails.push_back(emit(Op16::JUMP_IF_FALSE));
        for (int i = 0; i < n; ++i)
          sub(*p.subs[static_cast<size_t>(i)], [&, i] {
            emit(Op16::LOAD_LOCAL, slot);
            emit(Op16::PUSH_CONST, constInt(i));
            emit(Op16::INDEX_GET);
          });
        if (p.var) {
          emit(Op16::LOAD_LOCAL, slot);
          emit(Op16::LIST_REST, n);
          p.var->slot = allocSlot();
          emit(Op16::STORE_LOCAL, p.var->slot);
        }
        break;
      }
      default: break;
    }
  }

  // --------------------------------------------------------- expressions

  void compileExpr(Expr& e) {
    switch (e.kind) {
      case EK::Int: emit(Op16::PUSH_CONST, constInt(e.ival)); break;
      case EK::Float: emit(Op16::PUSH_CONST, constFloat(e.fval)); break;
      case EK::Str: emit(Op16::PUSH_CONST, constStr(e.sval)); break;
      case EK::Char: emit(Op16::PUSH_CONST, constChar(e.ival)); break;
      case EK::Bool: emit(e.bval ? Op16::PUSH_TRUE : Op16::PUSH_FALSE); break;
      case EK::SelfRef: loadVar(e.var); break;
      case EK::Path:
        if (e.pathKind == PathKind::Local) loadVar(e.var);
        else emit(Op16::MAKE_ENUM, e.id, e.id2, 0);
        break;
      case EK::StructLit: compileStructLit(e); break;
      case EK::List:
        for (auto& a : e.args) compileExpr(*a);
        emit(Op16::MAKE_LIST, static_cast<int>(e.args.size()));
        break;
      case EK::Map:
        for (size_t i = 0; i < e.args.size(); ++i) {
          compileExpr(*e.args[i]);
          compileExpr(*e.args2[i]);
        }
        emit(Op16::MAKE_MAP, static_cast<int>(e.args.size()));
        break;
      case EK::Tuple:
        for (auto& a : e.args) compileExpr(*a);
        emit(Op16::MAKE_TUPLE, static_cast<int>(e.args.size()));
        break;
      case EK::Lambda: compileLambda(e); break;
      case EK::If: compileIf(e); break;
      case EK::Match: compileMatch(e); break;
      case EK::Unary:
        compileExpr(*e.lhs);
        emit(e.op == Op::Neg ? (e.isFloat ? Op16::NEG_F : Op16::NEG_I) : e.op == Op::Not ? Op16::NOT_B : Op16::BNOT);
        break;
      case EK::Binary: compileBinary(e); break;
      case EK::Call: case EK::MethodCall: compileCall(e); break;
      case EK::Index:
        compileExpr(*e.lhs);
        compileExpr(*e.rhs);
        emit(Op16::INDEX_GET);
        break;
      case EK::Field:
        compileExpr(*e.lhs);
        emit(Op16::GET_FIELD, e.id2);
        break;
    }
  }

  void compileBinary(Expr& e) {
    if (e.op == Op::And || e.op == Op::Or) {
      bool isAnd = e.op == Op::And;
      compileExpr(*e.lhs);
      size_t j = emit(isAnd ? Op16::JUMP_IF_FALSE : Op16::JUMP_IF_TRUE);
      compileExpr(*e.rhs);
      size_t end = emit(Op16::JUMP);
      patch(j, here());
      cur().depth -= 1;
      emit(isAnd ? Op16::PUSH_FALSE : Op16::PUSH_TRUE);
      patch(end, here());
      return;
    }
    compileExpr(*e.lhs);
    compileExpr(*e.rhs);
    bool f = e.isFloat;
    Op16 op = Op16::ADD_I;
    switch (e.op) {
      case Op::Add: op = f ? Op16::ADD_F : Op16::ADD_I; break;
      case Op::Sub: op = f ? Op16::SUB_F : Op16::SUB_I; break;
      case Op::Mul: op = f ? Op16::MUL_F : Op16::MUL_I; break;
      case Op::Div: op = f ? Op16::DIV_F : Op16::DIV_I; break;
      case Op::Mod: op = Op16::MOD_I; break;
      case Op::Concat: op = Op16::CONCAT; break;
      case Op::BitAnd: op = Op16::BAND; break;
      case Op::BitOr: op = Op16::BOR; break;
      case Op::BitXor: op = Op16::BXOR; break;
      case Op::Shl: op = Op16::SHL; break;
      case Op::Shr: op = Op16::SHR; break;
      case Op::Lt: op = Op16::LT; break;
      case Op::Le: op = Op16::LE; break;
      case Op::Gt: op = Op16::GT; break;
      case Op::Ge: op = Op16::GE; break;
      case Op::Eq: op = Op16::EQ; break;
      case Op::Ne: op = Op16::NE; break;
      default: break;
    }
    emit(op);
  }

  void compileCall(Expr& e) {
    int argc = static_cast<int>(e.args.size());
    switch (e.callKind) {
      case CallKind::Func:
        for (auto& a : e.args) compileExpr(*a);
        emit(Op16::CALL, e.id, 0, argc);
        break;
      case CallKind::Builtin:
        for (auto& a : e.args) compileExpr(*a);
        emit(Op16::CALL_BUILTIN, e.id, 0, argc);
        break;
      case CallKind::Variant:
        for (auto& a : e.args) compileExpr(*a);
        emit(Op16::MAKE_ENUM, e.id, e.id2, argc);
        break;
      case CallKind::Indirect:
        compileExpr(*e.lhs);
        for (auto& a : e.args) compileExpr(*a);
        emit(Op16::CALL_VALUE, 0, 0, argc);
        break;
      case CallKind::Method:
        if (e.kind == EK::MethodCall) {
          compileExpr(*e.lhs);
          for (auto& a : e.args) compileExpr(*a);
          emit(Op16::CALL_METHOD, e.id, e.id2, argc);
        } else {
          for (auto& a : e.args) compileExpr(*a);
          emit(Op16::CALL_METHOD, e.id, e.id2, argc - 1);
        }
        break;
      default: break;
    }
  }

  void compileStructLit(Expr& e) {
    size_t n = e.fields.size();
    bool inOrder = true;
    for (size_t i = 0; i < n; ++i)
      if (e.fields[i].fieldIdx != static_cast<int>(i)) inOrder = false;
    if (inOrder) {
      for (FieldInit& f : e.fields) compileExpr(*f.value);
    } else {
      SlotScope sc(*this);
      std::vector<int> tmp(n);
      for (size_t i = 0; i < n; ++i) {
        compileExpr(*e.fields[i].value);
        tmp[i] = allocSlot();
        emit(Op16::STORE_LOCAL, tmp[i]);
      }
      for (size_t k = 0; k < n; ++k)
        for (size_t i = 0; i < n; ++i)
          if (e.fields[i].fieldIdx == static_cast<int>(k)) emit(Op16::LOAD_LOCAL, tmp[i]);
    }
    emit(Op16::MAKE_STRUCT, e.id, static_cast<int>(n));
  }

  void compileIf(Expr& e) {
    compileExpr(*e.cond);
    size_t toElse = emit(Op16::JUMP_IF_FALSE);
    int d = cur().depth;
    compileBlockValue(*e.thenB);
    size_t toEnd = emit(Op16::JUMP);
    patch(toElse, here());
    cur().depth = d;
    if (e.elseB) compileBlockValue(*e.elseB);
    else if (e.elseIf) compileExpr(*e.elseIf);
    else emit(Op16::PUSH_UNIT);
    patch(toEnd, here());
  }

  void compileMatch(Expr& e) {
    SlotScope sc(*this);
    int scrut = allocSlot();
    compileExpr(*e.scrut);
    emit(Op16::STORE_LOCAL, scrut);
    int d = cur().depth;
    std::vector<size_t> toEnd;
    for (Arm& arm : e.arms) {
      SlotScope armScope(*this);
      std::vector<size_t> fails;
      compilePattern(*arm.pat, scrut, fails);
      if (arm.guard) {
        compileExpr(*arm.guard);
        fails.push_back(emit(Op16::JUMP_IF_FALSE));
      }
      compileBlockValue(*arm.body);
      toEnd.push_back(emit(Op16::JUMP));
      patchHere(fails);
      cur().depth = d;
    }
    emit(Op16::NO_MATCH);
    emit(Op16::PUSH_UNIT);
    patchHere(toEnd);
  }
};

}  // namespace

std::unique_ptr<Program::Impl> compileProgram(Model& model) { return Compiler(model).run(); }

}  // namespace langvm
