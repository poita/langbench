#include "typeinfer/session.hpp"

#include "typeinfer/arena.hpp"
#include "typeinfer/environment.hpp"
#include "typeinfer/inference.hpp"
#include "typeinfer/parser.hpp"
#include "typeinfer/printer.hpp"
#include "typeinfer/symbol.hpp"
#include "typeinfer/types.hpp"

namespace typeinfer {

const char* to_string(ErrorKind kind) noexcept {
    switch (kind) {
        case ErrorKind::Unify: return "unify";
        case ErrorKind::Occurs: return "occurs";
        case ErrorKind::Unbound: return "unbound";
    }
    return "?";
}

std::string DeclResult::to_string() const {
    if (error) return std::string("error: ") + typeinfer::to_string(*error);
    return (name ? *name : std::string("-")) + " : " + type;
}

struct Session::Impl {
    TypeStore store;
    SymbolTable symbols;
    Environment env;
    Arena ast_arena;

    Impl() { install_builtins(); }

    void install_builtins() {
        Type* I = store.int_type();
        Type* B = store.bool_type();
        auto def = [&](const char* name, Type* t) {
            env.define(symbols.intern(name), {t, true});
        };
        auto fn = [&](Type* a, Type* b) { return store.fun(a, b); };
        auto fn3 = [&](Type* a, Type* b, Type* c) { return fn(a, fn(b, c)); };
        auto pair = [&](Type* a, Type* b) {
            Type* ts[] = {a, b};
            return store.tuple(ts);
        };
        auto lst = [&](Type* a) { return store.list(a); };
        auto gv = [&] { return store.generic_var(); };

        def("not", fn(B, B));
        {
            Type *a = gv(), *b = gv();
            def("fst", fn(pair(a, b), a));
        }
        {
            Type *a = gv(), *b = gv();
            def("snd", fn(pair(a, b), b));
        }
        {
            Type* a = gv();
            def("hd", fn(lst(a), a));
        }
        {
            Type* a = gv();
            def("tl", fn(lst(a), lst(a)));
        }
        {
            Type* a = gv();
            def("null", fn(lst(a), B));
        }
        {
            Type* a = gv();
            def("length", fn(lst(a), I));
        }
        {
            Type *a = gv(), *b = gv();
            def("map", fn3(fn(a, b), lst(a), lst(b)));
        }
        {
            Type *a = gv(), *b = gv();
            def("fold", fn(fn3(a, b, a), fn3(a, lst(b), a)));
        }
    }
};

Session::Session() : impl_(std::make_unique<Impl>()) {}
Session::~Session() = default;
Session::Session(Session&&) noexcept = default;
Session& Session::operator=(Session&&) noexcept = default;

std::vector<DeclResult> Session::check(std::string_view source) {
    std::vector<DeclResult> results;
    check_each(source, [&](DeclResult&& r) { results.push_back(std::move(r)); });
    return results;
}

void Session::check_each(std::string_view source,
                         const std::function<void(DeclResult&&)>& sink) {
    Impl& s = *impl_;
    std::vector<Token> tokens = tokenize(source);
    Parser parser(tokens, s.symbols, s.ast_arena);
    Inferencer inferencer(s.store, s.env);
    for (;;) {
        s.ast_arena.clear();
        std::optional<Decl> decl = parser.next_declaration();
        if (!decl) break;
        DeclResult r;
        try {
            Type* t = inferencer.infer_declaration(*decl);
            if (decl->kind != DeclKind::Expr) r.name = s.symbols.name(decl->name);
            r.type = print_type(s.store, t);
        } catch (const TypeError& e) {
            r.name.reset();
            r.error = e.kind();
        }
        sink(std::move(r));
    }
}

}  // namespace typeinfer
