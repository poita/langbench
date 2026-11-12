#include "typeinfer/types.hpp"

#include "typeinfer/errors.hpp"

namespace typeinfer {

TypeStore::TypeStore() {
    int_ = alloc(TypeKind::Int, 0);
    bool_ = alloc(TypeKind::Bool, 0);
    unit_ = alloc(TypeKind::Unit, 0);
}

Type* TypeStore::alloc(TypeKind kind, std::uint32_t nargs) {
    // Node and child array share one allocation.
    void* mem = arena_.allocate(sizeof(Type) + sizeof(Type*) * nargs, alignof(Type));
    Type* t = static_cast<Type*>(mem);
    t->kind = kind;
    t->nargs = nargs;
    t->level = 0;
    t->mark = 0;
    t->link = nullptr;
    t->aux.copy = nullptr;
    t->args = reinterpret_cast<Type**>(static_cast<char*>(mem) + sizeof(Type));
    return t;
}

Type* TypeStore::fresh_var(int level) {
    Type* t = alloc(TypeKind::Var, 0);
    t->level = level;
    return t;
}

Type* TypeStore::fun(Type* from, Type* to) {
    Type* t = alloc(TypeKind::Fun, 2);
    t->args[0] = from;
    t->args[1] = to;
    return t;
}

Type* TypeStore::list(Type* elem) {
    Type* t = alloc(TypeKind::List, 1);
    t->args[0] = elem;
    return t;
}

Type* TypeStore::tuple(std::span<Type* const> elems) {
    Type* t = alloc(TypeKind::Tuple, static_cast<std::uint32_t>(elems.size()));
    for (std::size_t i = 0; i < elems.size(); ++i) t->args[i] = elems[i];
    return t;
}

Type* TypeStore::repr(Type* t) {
    Type* r = t;
    while (r->link) r = r->link;
    while (t->link) {  // path compression
        Type* next = t->link;
        t->link = r;
        t = next;
    }
    return r;
}

void TypeStore::unify(Type* a, Type* b) {
    a = repr(a);
    b = repr(b);
    if (a == b) return;
    if (a->kind == TypeKind::Var) return bind(a, b);
    if (b->kind == TypeKind::Var) return bind(b, a);
    if (a->kind != b->kind || a->nargs != b->nargs) throw TypeError(ErrorKind::Unify);
    for (std::uint32_t i = 0; i < a->nargs; ++i) unify(a->args[i], b->args[i]);
    // The two nodes are now equal; merge them so shared sub-terms are not
    // unified again. (Done after the children, never before: linking early
    // would hide variables from the occurs check.)
    a->link = b;
}

// Binds the unbound variable `var` to `target` (a representative, != var).
void TypeStore::bind(Type* var, Type* target) {
    next_epoch();
    occurs_adjust(target, var);
    var->link = target;
}

// One walk over `t`: fails if `var` occurs in it, and lowers the level of
// every variable reached to at most `var`'s level.
void TypeStore::occurs_adjust(Type* t, Type* var) {
    for (;;) {
        t = repr(t);
        if (t->mark == epoch_) return;
        t->mark = epoch_;
        if (t->kind == TypeKind::Var) {
            if (t == var) throw TypeError(ErrorKind::Occurs);
            if (t->level > var->level) t->level = var->level;
            return;
        }
        if (t->nargs == 0) return;
        for (std::uint32_t i = 0; i + 1 < t->nargs; ++i) occurs_adjust(t->args[i], var);
        t = t->args[t->nargs - 1];
    }
}

bool TypeStore::generalize(Type* t, int level) {
    next_epoch();
    bool any = false;
    generalize_walk(t, level, any);
    return any;
}

void TypeStore::generalize_walk(Type* t, int level, bool& any) {
    for (;;) {
        t = repr(t);
        if (t->mark == epoch_) return;
        t->mark = epoch_;
        if (t->kind == TypeKind::Var) {
            if (t->level > level) {
                t->level = kGenericLevel;
                any = true;
            }
            return;
        }
        if (t->nargs == 0) return;
        for (std::uint32_t i = 0; i + 1 < t->nargs; ++i) generalize_walk(t->args[i], level, any);
        t = t->args[t->nargs - 1];
    }
}

Type* TypeStore::instantiate(Type* t, int level) {
    next_epoch();
    return instantiate_walk(t, level);
}

Type* TypeStore::instantiate_walk(Type* t, int level) {
    t = repr(t);
    if (t->mark == epoch_) return t->aux.copy;
    Type* result = t;
    if (t->kind == TypeKind::Var) {
        if (t->level == kGenericLevel) result = fresh_var(level);
    } else if (t->nargs > 0) {
        Type** fresh = nullptr;  // allocated lazily, once a child changes
        for (std::uint32_t i = 0; i < t->nargs; ++i) {
            Type* c = instantiate_walk(t->args[i], level);
            if (!fresh && c != repr(t->args[i])) {
                result = alloc(t->kind, t->nargs);
                fresh = result->args;
                for (std::uint32_t j = 0; j < i; ++j) fresh[j] = repr(t->args[j]);
            }
            if (fresh) fresh[i] = c;
        }
    }
    t->mark = epoch_;
    t->aux.copy = result;
    return result;
}

}  // namespace typeinfer
