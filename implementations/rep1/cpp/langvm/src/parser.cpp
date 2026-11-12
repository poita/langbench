#include "parser.h"

#include "langvm/diagnostic.h"

namespace langvm {
namespace {

class Parser {
 public:
  explicit Parser(std::vector<Token> toks) : t_(std::move(toks)) {}

  ModuleAst parseModuleBody() {
    ModuleAst m;
    while (cur().kind != Tok::Eof) parseItem(m);
    return m;
  }

 private:
  std::vector<Token> t_;
  size_t i_ = 0;

  const Token& cur() const { return t_[i_]; }
  const Token& peekTok(size_t k) const { return t_[std::min(i_ + k, t_.size() - 1)]; }
  Tok kind() const { return t_[i_].kind; }
  bool at(Tok k) const { return kind() == k; }
  Token& next() {
    Token& t = t_[i_];
    if (i_ + 1 < t_.size()) ++i_;
    return t;
  }
  [[noreturn]] void fail() const { throw CompileError(ErrorKind::Parse, cur().pos.line, cur().pos.col); }
  bool accept(Tok k) {
    if (at(k)) {
      next();
      return true;
    }
    return false;
  }
  Token& expect(Tok k) {
    if (!at(k)) fail();
    return next();
  }

  // ------------------------------------------------------------- items

  void parseItem(ModuleAst& m) {
    bool pub = false;
    if (at(Tok::KwPub)) {
      pub = true;
      next();
      if (!(at(Tok::KwFn) || at(Tok::KwStruct) || at(Tok::KwEnum) || at(Tok::KwTrait))) fail();
    }
    switch (kind()) {
      case Tok::KwUse: {
        auto u = std::make_unique<UseDecl>();
        u->pos = next().pos;
        Token& n = expect(Tok::Ident);
        u->module = n.text;
        u->modPos = n.pos;
        if (accept(Tok::KwAs)) {
          Token& a = expect(Tok::Ident);
          u->hasAlias = true;
          u->alias = a.text;
          u->aliasPos = a.pos;
        }
        expect(Tok::Semi);
        m.items.push_back({ItemKind::Use, m.uses.size()});
        m.uses.push_back(std::move(u));
        break;
      }
      case Tok::KwFn: {
        auto f = std::make_unique<FnDecl>();
        parseFn(*f, FnMode::Free);
        f->pub = pub;
        m.items.push_back({ItemKind::Fn, m.fns.size()});
        m.fns.push_back(std::move(f));
        break;
      }
      case Tok::KwStruct: {
        auto s = std::make_unique<StructDecl>();
        s->pub = pub;
        s->pos = next().pos;
        Token& n = expect(Tok::Ident);
        s->name = n.text;
        s->namePos = n.pos;
        if (at(Tok::Less)) s->generics = parseGenerics(false);
        expect(Tok::LBrace);
        while (!at(Tok::RBrace)) {
          FieldDecl f;
          Token& fn = expect(Tok::Ident);
          f.name = fn.text;
          f.pos = fn.pos;
          expect(Tok::Colon);
          f.type = parseType();
          s->fields.push_back(std::move(f));
          if (!accept(Tok::Comma)) break;
        }
        expect(Tok::RBrace);
        m.items.push_back({ItemKind::Struct, m.structs.size()});
        m.structs.push_back(std::move(s));
        break;
      }
      case Tok::KwEnum: {
        auto e = std::make_unique<EnumDecl>();
        e->pub = pub;
        e->pos = next().pos;
        Token& n = expect(Tok::Ident);
        e->name = n.text;
        e->namePos = n.pos;
        if (at(Tok::Less)) e->generics = parseGenerics(false);
        expect(Tok::LBrace);
        while (!at(Tok::RBrace)) {
          VariantDecl v;
          Token& vn = expect(Tok::Ident);
          v.name = vn.text;
          v.pos = vn.pos;
          if (accept(Tok::LParen)) {
            v.payload.push_back(parseType());
            while (accept(Tok::Comma)) {
              if (at(Tok::RParen)) break;
              v.payload.push_back(parseType());
            }
            expect(Tok::RParen);
          }
          e->variants.push_back(std::move(v));
          if (!accept(Tok::Comma)) break;
        }
        expect(Tok::RBrace);
        m.items.push_back({ItemKind::Enum, m.enums.size()});
        m.enums.push_back(std::move(e));
        break;
      }
      case Tok::KwTrait: {
        auto tr = std::make_unique<TraitDecl>();
        tr->pub = pub;
        tr->pos = next().pos;
        Token& n = expect(Tok::Ident);
        tr->name = n.text;
        tr->namePos = n.pos;
        expect(Tok::LBrace);
        while (!at(Tok::RBrace)) {
          FnDecl f;
          parseFn(f, FnMode::TraitMethod);
          tr->methods.push_back(std::move(f));
        }
        expect(Tok::RBrace);
        m.items.push_back({ItemKind::Trait, m.traits.size()});
        m.traits.push_back(std::move(tr));
        break;
      }
      case Tok::KwImpl: {
        auto im = std::make_unique<ImplDecl>();
        im->pos = next().pos;
        if (at(Tok::Less)) im->generics = parseGenerics(true);
        im->trait = parseTraitRef();
        expect(Tok::KwFor);
        im->head = parseType();
        expect(Tok::LBrace);
        while (!at(Tok::RBrace)) {
          FnDecl f;
          parseFn(f, FnMode::ImplMethod);
          im->methods.push_back(std::move(f));
        }
        expect(Tok::RBrace);
        m.items.push_back({ItemKind::Impl, m.impls.size()});
        m.impls.push_back(std::move(im));
        break;
      }
      default: fail();
    }
  }

  enum class FnMode { Free, TraitMethod, ImplMethod };

  void parseFn(FnDecl& f, FnMode mode) {
    f.pos = expect(Tok::KwFn).pos;
    Token& n = expect(Tok::Ident);
    f.name = n.text;
    f.namePos = n.pos;
    if (mode == FnMode::Free && at(Tok::Less)) f.generics = parseGenerics(true);
    expect(Tok::LParen);
    if (mode != FnMode::Free) {
      expect(Tok::KwSelf);
      f.hasSelf = true;
      if (accept(Tok::Comma)) parseParams(f.params);
    } else if (!at(Tok::RParen)) {
      parseParams(f.params);
    }
    expect(Tok::RParen);
    if (accept(Tok::Arrow)) f.ret = parseType();
    if (mode == FnMode::TraitMethod && at(Tok::Semi)) {
      next();
      return;
    }
    f.body = parseBlock();
  }

  void parseParams(std::vector<Param>& out) {
    for (;;) {
      Param p;
      Token& n = expect(Tok::Ident);
      p.name = n.text;
      p.pos = n.pos;
      expect(Tok::Colon);
      p.type = parseType();
      out.push_back(std::move(p));
      if (!accept(Tok::Comma)) break;
      if (at(Tok::RParen)) break;
    }
  }

  TraitRef parseTraitRef() {
    TraitRef r;
    Token& a = expect(Tok::Ident);
    r.pos = a.pos;
    if (accept(Tok::ColonColon)) {
      r.qual = a.text;
      r.qualPos = a.pos;
      Token& b = expect(Tok::Ident);
      r.name = b.text;
      r.namePos = b.pos;
    } else {
      r.name = a.text;
      r.namePos = a.pos;
    }
    return r;
  }

  std::vector<GenParam> parseGenerics(bool allowBounds) {
    std::vector<GenParam> out;
    expect(Tok::Less);
    for (;;) {
      GenParam g;
      Token& n = expect(Tok::Ident);
      g.name = n.text;
      g.pos = n.pos;
      if (at(Tok::Colon)) {
        if (!allowBounds) fail();
        next();
        g.bounds.push_back(parseTraitRef());
        while (accept(Tok::Plus)) g.bounds.push_back(parseTraitRef());
      }
      out.push_back(std::move(g));
      if (!accept(Tok::Comma)) break;
      if (at(Tok::Greater)) break;
    }
    expect(Tok::Greater);
    return out;
  }

  // ------------------------------------------------------------- types

  void closeAngle() {
    if (at(Tok::Greater)) {
      next();
    } else if (at(Tok::Shr)) {
      t_[i_].kind = Tok::Greater;  // `>>` closes two lists: consume one half now
    } else {
      fail();
    }
  }

  TypeExprP parseType() {
    auto t = std::make_unique<TypeExpr>();
    t->pos = cur().pos;
    switch (kind()) {
      case Tok::LBracket:
        next();
        t->kind = TypeExpr::K::List;
        t->args.push_back(parseType());
        expect(Tok::RBracket);
        return t;
      case Tok::HashBracket:
        next();
        t->kind = TypeExpr::K::Map;
        t->args.push_back(parseType());
        expect(Tok::Colon);
        t->args.push_back(parseType());
        expect(Tok::RBracket);
        return t;
      case Tok::LParen:
        next();
        t->kind = TypeExpr::K::Tuple;
        t->args.push_back(parseType());
        expect(Tok::Comma);
        t->args.push_back(parseType());
        while (accept(Tok::Comma)) {
          if (at(Tok::RParen)) break;
          t->args.push_back(parseType());
        }
        expect(Tok::RParen);
        return t;
      case Tok::KwFn:
        next();
        t->kind = TypeExpr::K::Fn;
        expect(Tok::LParen);
        if (!at(Tok::RParen)) {
          t->args.push_back(parseType());
          while (accept(Tok::Comma)) {
            if (at(Tok::RParen)) break;
            t->args.push_back(parseType());
          }
        }
        expect(Tok::RParen);
        if (accept(Tok::Arrow)) t->ret = parseType();
        return t;
      case Tok::Ident: {
        Token& a = next();
        t->kind = TypeExpr::K::Path;
        if (accept(Tok::ColonColon)) {
          t->qual = a.text;
          t->qualPos = a.pos;
          Token& b = expect(Tok::Ident);
          t->name = b.text;
          t->namePos = b.pos;
        } else {
          t->name = a.text;
          t->namePos = a.pos;
        }
        if (at(Tok::Less)) {
          next();
          t->hasArgs = true;
          t->args.push_back(parseType());
          while (accept(Tok::Comma)) {
            if (at(Tok::Greater) || at(Tok::Shr)) break;
            t->args.push_back(parseType());
          }
          closeAngle();
        }
        return t;
      }
      default: fail();
    }
  }

  // ------------------------------------------------------------ blocks

  BlockP parseBlock() {
    auto b = std::make_unique<Block>();
    b->pos = expect(Tok::LBrace).pos;
    while (!at(Tok::RBrace)) {
      if (parseStmtOrTail(*b)) break;
    }
    expect(Tok::RBrace);
    return b;
  }

  // Parses one statement into `b`; returns true if it was the trailing expression.
  bool parseStmtOrTail(Block& b) {
    auto s = std::make_unique<Stmt>();
    s->pos = cur().pos;
    switch (kind()) {
      case Tok::KwLet: {
        next();
        s->kind = Stmt::K::Let;
        s->pat = parsePattern();
        if (accept(Tok::Colon)) s->type = parseType();
        expect(Tok::Assign);
        s->expr = parseExpr();
        expect(Tok::Semi);
        break;
      }
      case Tok::KwVar: {
        next();
        s->kind = Stmt::K::Var;
        Token& n = expect(Tok::Ident);
        s->name = n.text;
        s->namePos = n.pos;
        if (accept(Tok::Colon)) s->type = parseType();
        expect(Tok::Assign);
        s->expr = parseExpr();
        expect(Tok::Semi);
        break;
      }
      case Tok::KwReturn:
        next();
        s->kind = Stmt::K::Return;
        if (!at(Tok::Semi)) s->expr = parseExpr();
        expect(Tok::Semi);
        break;
      case Tok::KwWhile:
        next();
        s->kind = Stmt::K::While;
        s->expr = parseExpr();
        s->body = parseBlock();
        break;
      case Tok::KwFor:
        next();
        s->kind = Stmt::K::For;
        s->pat = parsePattern();
        expect(Tok::KwIn);
        s->expr = parseExpr();
        if (accept(Tok::DotDot)) {
          s->isRange = true;
          s->expr2 = parseExpr();
        }
        s->body = parseBlock();
        break;
      case Tok::KwBreak:
        next();
        s->kind = Stmt::K::Break;
        expect(Tok::Semi);
        break;
      case Tok::KwContinue:
        next();
        s->kind = Stmt::K::Continue;
        expect(Tok::Semi);
        break;
      default: {
        ExprP e = parseExpr();
        if (accept(Tok::Assign)) {
          s->kind = Stmt::K::Assign;
          s->expr = std::move(e);
          s->expr2 = parseExpr();
          expect(Tok::Semi);
        } else if (accept(Tok::Semi)) {
          s->kind = Stmt::K::Expr;
          s->expr = std::move(e);
        } else if (at(Tok::RBrace)) {
          b.tail = std::move(e);
          return true;
        } else if (e->kind == EK::If || e->kind == EK::Match) {
          s->kind = Stmt::K::Expr;
          s->expr = std::move(e);
        } else {
          fail();
        }
        break;
      }
    }
    b.stmts.push_back(std::move(s));
    return false;
  }

  // ------------------------------------------------------- expressions

  static int binPrec(Tok k) {
    switch (k) {
      case Tok::OrOr: return 1;
      case Tok::AndAnd: return 2;
      case Tok::EqEq: case Tok::NotEq: case Tok::Less: case Tok::LessEq:
      case Tok::Greater: case Tok::GreaterEq: return 3;
      case Tok::Pipe: return 4;
      case Tok::Caret: return 5;
      case Tok::Amp: return 6;
      case Tok::Shl: case Tok::Shr: return 7;
      case Tok::Plus: case Tok::Minus: case Tok::PlusPlus: return 8;
      case Tok::Star: case Tok::Slash: case Tok::Percent: return 9;
      default: return 0;
    }
  }
  static Op binOp(Tok k) {
    switch (k) {
      case Tok::OrOr: return Op::Or;
      case Tok::AndAnd: return Op::And;
      case Tok::EqEq: return Op::Eq;
      case Tok::NotEq: return Op::Ne;
      case Tok::Less: return Op::Lt;
      case Tok::LessEq: return Op::Le;
      case Tok::Greater: return Op::Gt;
      case Tok::GreaterEq: return Op::Ge;
      case Tok::Pipe: return Op::BitOr;
      case Tok::Caret: return Op::BitXor;
      case Tok::Amp: return Op::BitAnd;
      case Tok::Shl: return Op::Shl;
      case Tok::Shr: return Op::Shr;
      case Tok::Plus: return Op::Add;
      case Tok::Minus: return Op::Sub;
      case Tok::PlusPlus: return Op::Concat;
      case Tok::Star: return Op::Mul;
      case Tok::Slash: return Op::Div;
      default: return Op::Mod;
    }
  }

  ExprP parseExpr() { return parseBin(1); }

  ExprP parseBin(int minPrec) {
    ExprP lhs = parseUnary();
    for (;;) {
      int p = binPrec(kind());
      if (p == 0 || p < minPrec) break;
      Tok opTok = next().kind;
      ExprP rhs = parseBin(p + 1);
      auto e = std::make_unique<Expr>();
      e->kind = EK::Binary;
      e->op = binOp(opTok);
      e->pos = lhs->pos;
      e->lhs = std::move(lhs);
      e->rhs = std::move(rhs);
      lhs = std::move(e);
      if (p == 3 && binPrec(kind()) == 3) fail();
    }
    return lhs;
  }

  ExprP parseUnary() {
    if (at(Tok::Minus) || at(Tok::Bang) || at(Tok::Tilde)) {
      auto e = std::make_unique<Expr>();
      e->kind = EK::Unary;
      e->pos = cur().pos;
      Tok k = next().kind;
      e->op = k == Tok::Minus ? Op::Neg : k == Tok::Bang ? Op::Not : Op::BitNot;
      e->lhs = parseUnary();
      return e;
    }
    return parsePostfix();
  }

  void parseArgs(std::vector<ExprP>& out, Tok close) {
    if (at(close)) return;
    for (;;) {
      out.push_back(parseExpr());
      if (!accept(Tok::Comma)) break;
      if (at(close)) break;
    }
  }

  ExprP parsePostfix() {
    ExprP e = parsePrimary();
    for (;;) {
      if (at(Tok::LParen)) {
        next();
        auto c = std::make_unique<Expr>();
        c->kind = EK::Call;
        c->pos = e->pos;
        c->lhs = std::move(e);
        parseArgs(c->args, Tok::RParen);
        expect(Tok::RParen);
        e = std::move(c);
      } else if (at(Tok::LBracket)) {
        next();
        auto c = std::make_unique<Expr>();
        c->kind = EK::Index;
        c->pos = e->pos;
        c->lhs = std::move(e);
        c->rhs = parseExpr();
        expect(Tok::RBracket);
        e = std::move(c);
      } else if (at(Tok::Dot)) {
        next();
        Token& n = expect(Tok::Ident);
        auto c = std::make_unique<Expr>();
        c->pos = e->pos;
        c->lhs = std::move(e);
        c->name = n.text;
        c->namePos = n.pos;
        if (at(Tok::LParen)) {
          next();
          c->kind = EK::MethodCall;
          parseArgs(c->args, Tok::RParen);
          expect(Tok::RParen);
        } else {
          c->kind = EK::Field;
        }
        e = std::move(c);
      } else {
        return e;
      }
    }
  }

  ExprP parsePrimary() {
    auto e = std::make_unique<Expr>();
    e->pos = cur().pos;
    switch (kind()) {
      case Tok::Int: e->kind = EK::Int; e->ival = next().intVal; return e;
      case Tok::Float: e->kind = EK::Float; e->fval = next().floatVal; return e;
      case Tok::Str: e->kind = EK::Str; e->sval = std::move(next().strVal); return e;
      case Tok::Char: e->kind = EK::Char; e->ival = next().intVal; return e;
      case Tok::KwTrue: next(); e->kind = EK::Bool; e->bval = true; return e;
      case Tok::KwFalse: next(); e->kind = EK::Bool; e->bval = false; return e;
      case Tok::KwSelf: next(); e->kind = EK::SelfRef; return e;
      case Tok::LParen: {
        next();
        ExprP first = parseExpr();
        if (accept(Tok::RParen)) return first;
        expect(Tok::Comma);
        e->kind = EK::Tuple;
        e->args.push_back(std::move(first));
        e->args.push_back(parseExpr());
        while (accept(Tok::Comma)) {
          if (at(Tok::RParen)) break;
          e->args.push_back(parseExpr());
        }
        expect(Tok::RParen);
        return e;
      }
      case Tok::LBracket:
        next();
        e->kind = EK::List;
        parseArgs(e->args, Tok::RBracket);
        expect(Tok::RBracket);
        return e;
      case Tok::HashBracket:
        next();
        e->kind = EK::Map;
        if (!at(Tok::RBracket)) {
          for (;;) {
            e->args.push_back(parseExpr());
            expect(Tok::Colon);
            e->args2.push_back(parseExpr());
            if (!accept(Tok::Comma)) break;
            if (at(Tok::RBracket)) break;
          }
        }
        expect(Tok::RBracket);
        return e;
      case Tok::OrOr:
      case Tok::Pipe: return parseLambda();
      case Tok::KwIf: return parseIf();
      case Tok::KwMatch: return parseMatch();
      case Tok::Ident: {
        Token& a = next();
        e->kind = EK::Path;
        if (accept(Tok::ColonColon)) {
          e->qual = a.text;
          e->qualPos = a.pos;
          Token& b = expect(Tok::Ident);
          e->name = b.text;
          e->namePos = b.pos;
        } else {
          e->name = a.text;
          e->namePos = a.pos;
        }
        if (at(Tok::Dot) && peekTok(1).kind == Tok::LBrace) {
          next();
          next();
          e->kind = EK::StructLit;
          if (!at(Tok::RBrace)) {
            for (;;) {
              FieldInit f;
              Token& fn = expect(Tok::Ident);
              f.name = fn.text;
              f.pos = fn.pos;
              expect(Tok::Colon);
              f.value = parseExpr();
              e->fields.push_back(std::move(f));
              if (!accept(Tok::Comma)) break;
              if (at(Tok::RBrace)) break;
            }
          }
          expect(Tok::RBrace);
        }
        return e;
      }
      default: fail();
    }
  }

  ExprP parseLambda() {
    auto e = std::make_unique<Expr>();
    e->kind = EK::Lambda;
    e->pos = cur().pos;
    if (accept(Tok::OrOr)) {
      // no parameters
    } else {
      next();  // `|`
      for (;;) {
        LParam p;
        Token& n = expect(Tok::Ident);
        p.name = n.text;
        p.pos = n.pos;
        if (accept(Tok::Colon)) p.type = parseType();
        e->lparams.push_back(std::move(p));
        if (!accept(Tok::Comma)) break;
        if (at(Tok::Pipe)) break;
      }
      expect(Tok::Pipe);
    }
    if (accept(Tok::Arrow)) e->lret = parseType();
    if (at(Tok::LBrace)) {
      e->body = parseBlock();
    } else {
      e->body = std::make_unique<Block>();
      e->body->pos = cur().pos;
      e->body->tail = parseExpr();
    }
    return e;
  }

  ExprP parseIf() {
    auto e = std::make_unique<Expr>();
    e->kind = EK::If;
    e->pos = expect(Tok::KwIf).pos;
    e->cond = parseExpr();
    e->thenB = parseBlock();
    if (accept(Tok::KwElse)) {
      if (at(Tok::KwIf)) {
        e->elseIf = parseIf();
      } else {
        e->elseB = parseBlock();
      }
    }
    return e;
  }

  ExprP parseMatch() {
    auto e = std::make_unique<Expr>();
    e->kind = EK::Match;
    e->pos = expect(Tok::KwMatch).pos;
    e->scrut = parseExpr();
    expect(Tok::LBrace);
    while (!at(Tok::RBrace)) {
      Arm a;
      a.pos = cur().pos;
      a.pat = parsePattern();
      if (accept(Tok::KwWhen)) a.guard = parseExpr();
      expect(Tok::Arrow);
      bool blockBody = at(Tok::LBrace);
      if (blockBody) {
        a.body = parseBlock();
      } else {
        a.body = std::make_unique<Block>();
        a.body->pos = cur().pos;
        a.body->tail = parseExpr();
      }
      e->arms.push_back(std::move(a));
      if (!accept(Tok::Comma) && !blockBody) {
        if (!at(Tok::RBrace)) fail();
      }
    }
    expect(Tok::RBrace);
    return e;
  }

  // ---------------------------------------------------------- patterns

  PatternP parsePattern() {
    auto p = std::make_unique<Pattern>();
    p->pos = cur().pos;
    switch (kind()) {
      case Tok::Underscore: next(); p->kind = Pattern::K::Wild; return p;
      case Tok::Int: p->kind = Pattern::K::Int; p->ival = next().intVal; return p;
      case Tok::Float: p->kind = Pattern::K::Float; p->fval = next().floatVal; return p;
      case Tok::Minus: {
        next();
        if (at(Tok::Int)) {
          p->kind = Pattern::K::Int;
          p->ival = static_cast<int64_t>(0 - static_cast<uint64_t>(next().intVal));
        } else if (at(Tok::Float)) {
          p->kind = Pattern::K::Float;
          p->fval = -next().floatVal;
        } else {
          fail();
        }
        return p;
      }
      case Tok::Str: p->kind = Pattern::K::Str; p->sval = std::move(next().strVal); return p;
      case Tok::Char: p->kind = Pattern::K::Char; p->ival = next().intVal; return p;
      case Tok::KwTrue: next(); p->kind = Pattern::K::Bool; p->bval = true; return p;
      case Tok::KwFalse: next(); p->kind = Pattern::K::Bool; p->bval = false; return p;
      case Tok::LParen:
        next();
        p->kind = Pattern::K::Tuple;
        p->subs.push_back(parsePattern());
        expect(Tok::Comma);
        p->subs.push_back(parsePattern());
        while (accept(Tok::Comma)) {
          if (at(Tok::RParen)) break;
          p->subs.push_back(parsePattern());
        }
        expect(Tok::RParen);
        return p;
      case Tok::LBracket:
        next();
        p->kind = Pattern::K::List;
        while (!at(Tok::RBracket)) {
          if (at(Tok::DotDot)) {
            next();
            p->hasRest = true;
            if (at(Tok::Ident)) {
              Token& n = next();
              p->restName = n.text;
              p->restPos = n.pos;
            }
            break;
          }
          p->subs.push_back(parsePattern());
          if (!accept(Tok::Comma)) break;
        }
        expect(Tok::RBracket);
        return p;
      case Tok::Ident: {
        Token& a = next();
        p->kind = Pattern::K::Path;
        if (accept(Tok::ColonColon)) {
          p->qual = a.text;
          p->qualPos = a.pos;
          Token& b = expect(Tok::Ident);
          p->name = b.text;
          p->namePos = b.pos;
        } else {
          p->name = a.text;
          p->namePos = a.pos;
        }
        if (at(Tok::Dot) && peekTok(1).kind == Tok::LBrace) {
          next();
          next();
          p->kind = Pattern::K::Struct;
          while (!at(Tok::RBrace)) {
            if (at(Tok::DotDot)) {
              next();
              p->hasDots = true;
              break;
            }
            FieldPat f;
            Token& fn = expect(Tok::Ident);
            f.name = fn.text;
            f.pos = fn.pos;
            if (accept(Tok::Colon)) {
              f.pat = parsePattern();
            } else {
              f.pat = std::make_unique<Pattern>();
              f.pat->kind = Pattern::K::Bind;
              f.pat->pos = fn.pos;
              f.pat->name = fn.text;
              f.pat->namePos = fn.pos;
            }
            p->fields.push_back(std::move(f));
            if (!accept(Tok::Comma)) break;
          }
          expect(Tok::RBrace);
        } else if (at(Tok::LParen)) {
          next();
          p->hasParens = true;
          p->subs.push_back(parsePattern());
          while (accept(Tok::Comma)) {
            if (at(Tok::RParen)) break;
            p->subs.push_back(parsePattern());
          }
          expect(Tok::RParen);
        }
        return p;
      }
      default: fail();
    }
  }
};

}  // namespace

ModuleAst parseModule(std::vector<Token> tokens) { return Parser(std::move(tokens)).parseModuleBody(); }

}  // namespace langvm
