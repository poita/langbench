// Interned identifiers.
#pragma once

#include <cstdint>
#include <deque>
#include <string>
#include <string_view>
#include <unordered_map>

namespace typeinfer {

/// Dense integer id of an interned identifier.
using Symbol = std::uint32_t;

/// Maps identifier spellings to dense `Symbol` ids and back.
class SymbolTable {
public:
    /// Returns the symbol for `name`, creating it if necessary.
    Symbol intern(std::string_view name) {
        auto it = index_.find(name);
        if (it != index_.end()) return it->second;
        names_.emplace_back(name);
        Symbol id = static_cast<Symbol>(names_.size() - 1);
        index_.emplace(std::string_view(names_.back()), id);
        return id;
    }
    const std::string& name(Symbol s) const { return names_[s]; }
    std::size_t size() const { return names_.size(); }

private:
    std::deque<std::string> names_;  // deque: element addresses are stable
    std::unordered_map<std::string_view, Symbol> index_;
};

}  // namespace typeinfer
