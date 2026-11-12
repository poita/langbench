// The card database: reads and validates a Spiremark `.spire` file.
#pragma once

#include <map>
#include <memory>
#include <string>

#include "spiremark/card.hpp"
#include "spiremark/sexpr.hpp"

namespace spiremark {

/// An immutable, validated set of cards keyed by id.
class Database {
public:
    /// Parses and validates database text. Throws DatabaseError on any violation
    /// of SPEC.md section 5.
    static Database parse(const std::string& source);
    /// Reads a file and parses it. Throws DatabaseError if it cannot be read.
    static Database load_file(const std::string& path);

    /// The card with this id, or nullptr.
    const Card* find(const std::string& id) const;
    std::size_t size() const { return cards_.size(); }

    /// The `CARD BEGIN ... CARD END` block for an id (SPEC.md 23.4), including
    /// the `unknown` form. Lines are '\n'-terminated.
    std::string describe(const std::string& id) const;

private:
    // Cards are stored behind unique_ptr so Card pointers stay stable.
    std::map<std::string, std::unique_ptr<Card>> cards_;
};

}  // namespace spiremark
