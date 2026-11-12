#include "typeinfer/printer.hpp"

namespace typeinfer {

namespace {

// How much protection the surrounding context demands.
enum class Ctx {
    Free,       // top level, or right of an arrow
    ArrowLeft,  // function types need parentheses
    Atomic,     // function and tuple types need parentheses
};

struct Printer {
    TypeStore& store;
    std::string& out;
    std::uint32_t next_var = 0;

    void var_name(std::uint32_t i) {
        out += '\'';
        out += static_cast<char>('a' + i % 26);
        if (i >= 26) out += std::to_string(i / 26);
    }

    void go(Type* t, Ctx ctx) {
        t = TypeStore::repr(t);
        switch (t->kind) {
            case TypeKind::Var:
                if (t->mark != store.epoch()) {
                    t->mark = store.epoch();
                    t->aux.index = next_var++;
                }
                var_name(t->aux.index);
                return;
            case TypeKind::Int: out += "int"; return;
            case TypeKind::Bool: out += "bool"; return;
            case TypeKind::Unit: out += "unit"; return;
            case TypeKind::List:
                go(t->args[0], Ctx::Atomic);
                out += " list";
                return;
            case TypeKind::Fun: {
                bool paren = ctx != Ctx::Free;
                if (paren) out += '(';
                go(t->args[0], Ctx::ArrowLeft);
                out += " -> ";
                go(t->args[1], Ctx::Free);
                if (paren) out += ')';
                return;
            }
            case TypeKind::Tuple: {
                bool paren = ctx == Ctx::Atomic;
                if (paren) out += '(';
                for (std::uint32_t i = 0; i < t->nargs; ++i) {
                    if (i) out += " * ";
                    go(t->args[i], Ctx::Atomic);
                }
                if (paren) out += ')';
                return;
            }
        }
    }
};

}  // namespace

std::string print_type(TypeStore& store, Type* t) {
    std::string out;
    store.next_epoch();
    Printer p{store, out};
    p.go(t, Ctx::Free);
    return out;
}

}  // namespace typeinfer
