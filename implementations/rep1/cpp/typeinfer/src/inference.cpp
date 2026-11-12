#include "typeinfer/inference.hpp"

#include <vector>

#include "typeinfer/errors.hpp"

namespace typeinfer {

Type* Inferencer::lookup(Symbol name) {
    const Binding* b = env_.lookup(name);
    if (!b) throw TypeError(ErrorKind::Unbound);
    if (!b->polymorphic) return b->type;
    return store_.instantiate(b->type, level_);
}

// fun params -> body, with one monomorphic variable per parameter.
Type* Inferencer::infer_lambda(std::span<const Symbol> params, const Expr& body) {
    std::vector<Type*> vars;
    vars.reserve(params.size());
    for (Symbol p : params) {
        Type* v = store_.fresh_var(level_);
        vars.push_back(v);
        env_.push(p, {v, false});
    }
    Type* t = infer(body);
    for (std::size_t i = 0; i < params.size(); ++i) env_.pop();
    for (std::size_t i = vars.size(); i-- > 0;) t = store_.fun(vars[i], t);
    return t;
}

// f a1 ... an, as the chain of nested applications ((f a1) a2) ... an.
Type* Inferencer::infer_application(const Expr& e) {
    Type* tf = infer(*e.first);
    for (const Expr* arg : e.items) {
        Type* ta = infer(*arg);
        Type* result = store_.fresh_var(level_);
        store_.unify(tf, store_.fun(ta, result));
        tf = result;
    }
    return tf;
}

// Infers and generalises the right-hand side of `let [rec] name params = rhs`.
Binding Inferencer::infer_binding(bool rec, Symbol name, std::span<const Symbol> params,
                                  const Expr& rhs) {
    ++level_;
    Type* t;
    if (rec) {
        Type* self = store_.fresh_var(level_);
        env_.push(name, {self, false});
        Type* fn = infer_lambda(params, rhs);
        env_.pop();
        store_.unify(self, fn);
        t = self;
    } else {
        t = params.empty() ? infer(rhs) : infer_lambda(params, rhs);
    }
    --level_;
    bool poly = store_.generalize(t, level_);
    return {t, poly};
}

Type* Inferencer::infer(const Expr& e) {
    switch (e.kind) {
        case ExprKind::Int: return store_.int_type();
        case ExprKind::Bool: return store_.bool_type();
        case ExprKind::Unit: return store_.unit_type();
        case ExprKind::Var: return lookup(e.name);
        case ExprKind::Nil: return store_.list(store_.fresh_var(level_));
        case ExprKind::Tuple: {
            std::vector<Type*> ts;
            ts.reserve(e.items.size());
            for (const Expr* x : e.items) ts.push_back(infer(*x));
            return store_.tuple(ts);
        }
        case ExprKind::List: {
            Type* elem = store_.fresh_var(level_);
            for (const Expr* x : e.items) store_.unify(elem, infer(*x));
            return store_.list(elem);
        }
        case ExprKind::Cons: {
            Type* head = infer(*e.first);
            Type* tail = infer(*e.second);
            Type* result = store_.list(head);
            store_.unify(tail, result);
            return result;
        }
        case ExprKind::Binary: {
            bool logic = e.op == BinaryOp::And || e.op == BinaryOp::Or;
            Type* operand = logic ? store_.bool_type() : store_.int_type();
            store_.unify(infer(*e.first), operand);
            store_.unify(infer(*e.second), operand);
            switch (e.op) {
                case BinaryOp::Add:
                case BinaryOp::Sub:
                case BinaryOp::Mul:
                case BinaryOp::Div: return store_.int_type();
                default: return store_.bool_type();
            }
        }
        case ExprKind::App: return infer_application(e);
        case ExprKind::Lambda: return infer_lambda(e.params, *e.second);
        case ExprKind::If: {
            store_.unify(infer(*e.first), store_.bool_type());
            Type* a = infer(*e.second);
            Type* b = infer(*e.third);
            store_.unify(a, b);
            return a;
        }
        case ExprKind::Let:
        case ExprKind::LetRec: {
            Binding b = infer_binding(e.kind == ExprKind::LetRec, e.name, e.params, *e.first);
            env_.push(e.name, b);
            Type* t = infer(*e.second);
            env_.pop();
            return t;
        }
    }
    return nullptr;  // unreachable
}

Type* Inferencer::infer_declaration(const Decl& d) {
    std::size_t mark = env_.mark();
    try {
        if (d.kind == DeclKind::Expr) {
            ++level_;
            Type* t = infer(*d.body);
            --level_;
            return t;
        }
        Binding b = infer_binding(d.kind == DeclKind::LetRec, d.name, d.params, *d.body);
        env_.define(d.name, b);
        return b.type;
    } catch (...) {
        env_.rollback(mark);
        level_ = 0;
        throw;
    }
}

}  // namespace typeinfer
