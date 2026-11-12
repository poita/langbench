#include "scheme/interpreter.hpp"

#include <ostream>
#include <iostream>

#include "scheme/ast.hpp"
#include "scheme/primitives.hpp"
#include "scheme/printer.hpp"
#include "scheme/reader.hpp"

namespace scheme {

Interpreter::Interpreter() : analyzer_(symbols_), out_(&std::cout) { install_primitives(*this); }

void Interpreter::define_global(std::string_view name, Value value) {
  Symbol* s = symbols_.intern(name);
  s->global = std::move(value);
  s->bound = true;
}

void Interpreter::define_primitive(const char* name, int min_args, int max_args, PrimitiveFn fn) {
  define_global(name, Value(new Primitive(name, min_args, max_args, fn)));
}

RunResult Interpreter::run(std::string_view source, std::ostream& out) {
  std::ostream* saved = out_;
  out_ = &out;
  RunResult result;
  try {
    Reader reader(source, symbols_);
    std::string text;
    while (auto datum = reader.read()) {
      Value v = eval(*datum);
      if (!v.is_void()) {
        text.clear();
        print_value(text, v, false);
        text.push_back('\n');
        out << text;
      }
    }
  } catch (const SchemeError& e) {
    out << "error: " << error_name(e.kind()) << '\n';
    result.ok = false;
    result.error = e.kind();
  }
  out_ = saved;
  return result;
}

Value Interpreter::eval_string(std::string_view source) {
  Reader reader(source, symbols_);
  Value last;
  while (auto datum = reader.read()) last = eval(*datum);
  return last;
}

Value Interpreter::eval(const Value& datum) { return eval_node(analyzer_.analyze(datum), nullptr); }

Ref<Frame> Interpreter::bind_arguments(const Closure& c, std::vector<Value>& args) {
  const LambdaNode& lam = *c.lambda;
  const size_t np = lam.params.size();
  if (args.size() < np || (!lam.rest && args.size() > np)) throw SchemeError(ErrorKind::ArityError);
  Ref<Frame> frame(new Frame(c.env));
  frame->bindings.reserve(np + (lam.rest ? 1 : 0) + 1);
  for (size_t i = 0; i < np; ++i) frame->bindings.push_back(Binding{lam.params[i], std::move(args[i])});
  if (lam.rest) {
    Value rest = Value::null();
    for (size_t i = args.size(); i-- > np;) rest = make_pair(std::move(args[i]), std::move(rest));
    frame->bindings.push_back(Binding{lam.rest, std::move(rest)});
  }
  return frame;
}

// The evaluator loop. Tail positions reassign `node`/`env` and loop instead of
// recursing, so tail calls run in constant native stack. `owner` keeps the
// current frame alive; `env` is the same frame as a raw pointer.
Value Interpreter::eval_node(const Node* node, Frame* env) {
  Ref<Frame> owner;  // frame created by this activation (if any)
  for (;;) {
    switch (node->kind) {
      case NodeKind::Const:
        return static_cast<const ConstNode*>(node)->value;

      case NodeKind::Var: {
        Symbol* sym = static_cast<const VarNode*>(node)->name;
        for (Frame* f = env; f; f = f->parent.get())
          if (Value* slot = f->find(sym)) return *slot;
        if (!sym->bound) throw SchemeError(ErrorKind::UnboundVariable, sym->name);
        return sym->global;
      }

      case NodeKind::If: {
        auto* n = static_cast<const IfNode*>(node);
        if (eval_node(n->test, env).truthy()) {
          node = n->then;
        } else if (n->otherwise) {
          node = n->otherwise;
        } else {
          return Value();
        }
        continue;
      }

      case NodeKind::Define: {
        auto* n = static_cast<const DefineNode*>(node);
        Value v = eval_node(n->expr, env);
        if (env) {
          env->define(n->name, std::move(v));
        } else {
          n->name->global = std::move(v);
          n->name->bound = true;
        }
        return Value();
      }

      case NodeKind::Set: {
        auto* n = static_cast<const SetNode*>(node);
        Value v = eval_node(n->expr, env);
        for (Frame* f = env; f; f = f->parent.get()) {
          if (Value* slot = f->find(n->name)) {
            *slot = std::move(v);
            return Value();
          }
        }
        if (!n->name->bound) throw SchemeError(ErrorKind::UnboundVariable, n->name->name);
        n->name->global = std::move(v);
        return Value();
      }

      case NodeKind::Lambda:
        return Value(new Closure(static_cast<const LambdaNode*>(node), Ref<Frame>(env)));

      case NodeKind::Seq: {
        auto* n = static_cast<const SeqNode*>(node);
        for (size_t i = 0; i + 1 < n->forms.size(); ++i) eval_node(n->forms[i], env);
        node = n->forms.back();
        continue;
      }

      case NodeKind::Let: {
        auto* n = static_cast<const LetNode*>(node);
        Ref<Frame> frame(new Frame(Ref<Frame>(env)));
        frame->bindings.reserve(n->names.size() + 1);
        for (size_t i = 0; i < n->names.size(); ++i)
          frame->bindings.push_back(Binding{n->names[i], eval_node(n->inits[i], env)});
        owner = std::move(frame);
        env = owner.get();
        node = n->body;
        continue;
      }

      case NodeKind::Letrec: {
        auto* n = static_cast<const LetrecNode*>(node);
        Ref<Frame> frame(new Frame(Ref<Frame>(env)));
        owner = std::move(frame);
        env = owner.get();
        for (size_t i = 0; i < n->names.size(); ++i) env->define(n->names[i], eval_node(n->inits[i], env));
        node = n->body;
        continue;
      }

      case NodeKind::NamedLet: {
        auto* n = static_cast<const NamedLetNode*>(node);
        std::vector<Value> args;
        args.reserve(n->inits.size());
        for (const Node* init : n->inits) args.push_back(eval_node(init, env));
        Ref<Frame> loop_frame(new Frame(Ref<Frame>(env)));
        Ref<Closure> proc(new Closure(n->lambda, loop_frame));
        loop_frame->bindings.push_back(Binding{n->name, Value(proc)});
        Ref<Frame> call = bind_arguments(*proc, args);
        owner = std::move(call);
        env = owner.get();
        node = n->lambda->body;
        continue;
      }

      case NodeKind::Cond: {
        auto* n = static_cast<const CondNode*>(node);
        const Node* next = nullptr;
        bool matched = false;
        for (const CondClause& cl : n->clauses) {
          if (!cl.test) {
            next = cl.body;
            matched = true;
            break;
          }
          Value t = eval_node(cl.test, env);
          if (t.truthy()) {
            if (!cl.body) return t;
            next = cl.body;
            matched = true;
            break;
          }
        }
        if (!matched) return Value();
        node = next;
        continue;
      }

      case NodeKind::And:
      case NodeKind::Or: {
        auto* n = static_cast<const AndOrNode*>(node);
        const bool is_and = node->kind == NodeKind::And;
        for (size_t i = 0; i + 1 < n->forms.size(); ++i) {
          Value v = eval_node(n->forms[i], env);
          if (v.truthy() != is_and) return v;
        }
        node = n->forms.back();
        continue;
      }

      case NodeKind::App: {
        auto* n = static_cast<const AppNode*>(node);
        Value f = eval_node(n->fn, env);
        std::vector<Value> args;
        args.reserve(n->args.size());
        for (const Node* a : n->args) args.push_back(eval_node(a, env));
      apply_procedure:
        if (f.is_closure()) {
          Closure* c = f.as<Closure>();
          Ref<Frame> frame = bind_arguments(*c, args);
          node = c->lambda->body;
          owner = std::move(frame);
          env = owner.get();
          continue;
        }
        if (f.is_primitive()) {
          Primitive* p = f.as<Primitive>();
          const int argc = int(args.size());
          if (argc < p->min_args || (p->max_args >= 0 && argc > p->max_args))
            throw SchemeError(ErrorKind::ArityError, p->name);
          if (!p->is_apply) return p->fn(*this, args.data(), args.size());
          // (apply f a ... lst): spread the list and call again, as a tail call.
          std::vector<Value> spread;
          if (!list_to_vector(args.back(), spread)) throw SchemeError(ErrorKind::TypeError, "apply");
          std::vector<Value> next;
          next.reserve(args.size() - 2 + spread.size());
          for (size_t i = 1; i + 1 < args.size(); ++i) next.push_back(std::move(args[i]));
          for (auto& v : spread) next.push_back(std::move(v));
          Value target = std::move(args[0]);
          f = std::move(target);
          args = std::move(next);
          goto apply_procedure;
        }
        throw SchemeError(ErrorKind::TypeError, "not a procedure");
      }
    }
  }
}

}  // namespace scheme
