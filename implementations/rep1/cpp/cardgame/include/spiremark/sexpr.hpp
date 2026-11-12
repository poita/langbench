// S-expression reader used for the Spiremark card database format.
#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace spiremark {

/// Raised for any lexical, syntactic or semantic error in a card database.
struct DatabaseError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

/// A parsed s-expression node: a list, a symbol, a 64-bit integer or a string.
struct Sexpr {
    enum class Kind { List, Symbol, Integer, String };

    Kind kind = Kind::List;
    std::string text;           ///< symbol name or string contents
    std::int64_t value = 0;     ///< integer value (Kind::Integer)
    std::vector<Sexpr> items;   ///< children (Kind::List)

    bool is_list() const { return kind == Kind::List; }
    bool is_symbol() const { return kind == Kind::Symbol; }
    bool is_int() const { return kind == Kind::Integer; }
    bool is_string() const { return kind == Kind::String; }
    /// True when this is a list whose first element is the symbol `head`.
    bool is_form(const char* head) const;

    /// Canonical printing: single spaces, minimal integers, strings re-quoted.
    std::string print() const;
};

/// Parses a whole file into its top-level forms.
/// Throws DatabaseError on an unterminated string, unbalanced parentheses, etc.
std::vector<Sexpr> parse_sexprs(const std::string& source);

}  // namespace spiremark
