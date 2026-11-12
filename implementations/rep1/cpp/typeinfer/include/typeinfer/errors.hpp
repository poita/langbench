// Error types thrown by the typeinfer library.
#pragma once

#include <cstddef>
#include <exception>
#include <stdexcept>
#include <string>

namespace typeinfer {

/// The ways in which a declaration can fail to type-check.
enum class ErrorKind {
    Unify,    ///< Two incompatible type constructors met during unification.
    Occurs,   ///< Unification would build an infinite type.
    Unbound,  ///< A variable is not in scope.
};

/// Spelling of an error kind as printed by the CLI: "unify", "occurs", "unbound".
const char* to_string(ErrorKind kind) noexcept;

/// Thrown by the unifier and the inferencer when a declaration is ill-typed.
class TypeError : public std::exception {
public:
    explicit TypeError(ErrorKind kind) noexcept : kind_(kind) {}
    ErrorKind kind() const noexcept { return kind_; }
    const char* what() const noexcept override { return to_string(kind_); }

private:
    ErrorKind kind_;
};

/// Thrown by the lexer and parser on malformed input.
class ParseError : public std::runtime_error {
public:
    ParseError(const std::string& message, std::size_t offset)
        : std::runtime_error(message + " at offset " + std::to_string(offset)), offset_(offset) {}
    /// Byte offset in the source where the problem was detected.
    std::size_t offset() const noexcept { return offset_; }

private:
    std::size_t offset_;
};

}  // namespace typeinfer
