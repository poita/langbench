// The typing environment: name -> innermost binding.
#pragma once

#include <vector>

#include "typeinfer/symbol.hpp"
#include "typeinfer/types.hpp"

namespace typeinfer {

/// What a name is bound to.
struct Binding {
    Type* type;
    /// True if `type` is a scheme with quantified variables that must be
    /// instantiated at each use; false if it is used as it is (O(1)).
    bool polymorphic;
};

/// Scoped environment with O(1) lookup, independent of the number of
/// bindings in scope: each symbol has its own stack of bindings, and the
/// innermost one is on top.
class Environment {
public:
    /// Adds a permanent (top-level) binding. Must not be called while scoped
    /// bindings are active.
    void define(Symbol name, Binding b) { stack(name).push_back(b); }

    /// Adds a scoped binding; undone by `pop`.
    void push(Symbol name, Binding b) {
        stack(name).push_back(b);
        trail_.push_back(name);
    }
    /// Removes the most recent scoped binding.
    void pop() {
        stacks_[trail_.back()].pop_back();
        trail_.pop_back();
    }

    /// Number of active scoped bindings; pass to `rollback` to undo to here.
    std::size_t mark() const { return trail_.size(); }
    void rollback(std::size_t mark) {
        while (trail_.size() > mark) pop();
    }

    /// The innermost binding of `name`, or nullptr if unbound.
    const Binding* lookup(Symbol name) const {
        if (name >= stacks_.size() || stacks_[name].empty()) return nullptr;
        return &stacks_[name].back();
    }

private:
    std::vector<Binding>& stack(Symbol name) {
        if (name >= stacks_.size()) stacks_.resize(static_cast<std::size_t>(name) + 1);
        return stacks_[name];
    }

    std::vector<std::vector<Binding>> stacks_;
    std::vector<Symbol> trail_;
};

}  // namespace typeinfer
