// High-level API: check whole programs.
#pragma once

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "typeinfer/errors.hpp"

namespace typeinfer {

/// The outcome of checking one top-level declaration.
struct DeclResult {
    /// The bound name for `let` / `let rec`; empty for a bare expression.
    std::optional<std::string> name;
    /// The rendered principal type; empty if the declaration failed.
    std::string type;
    /// Set if the declaration failed to type-check.
    std::optional<ErrorKind> error;

    bool ok() const { return !error.has_value(); }

    /// The report line (without newline): "name : type", "- : type" or
    /// "error: kind".
    std::string to_string() const;
};

/// A type-checking session: the top-level environment, starting with the
/// built-ins, which accumulates the bindings of successful declarations.
///
/// Typical use:
/// @code
///   typeinfer::Session session;
///   for (const auto& r : session.check("let id = fun x -> x;; id 1;;"))
///       std::cout << r.to_string() << '\n';
/// @endcode
///
/// The implementation recurses on the nesting depth of the program and of the
/// inferred types; programs nested thousands of levels deep need a large call
/// stack (the bundled CLI arranges one).
class Session {
public:
    Session();
    ~Session();
    Session(Session&&) noexcept;
    Session& operator=(Session&&) noexcept;

    /// Checks every declaration of `source` (each terminated by `;;`) in
    /// order, extending the session's environment with the successful
    /// `let` bindings. A declaration that fails yields an error result and
    /// adds nothing. Throws `ParseError` if the text is not well formed;
    /// declarations preceding the problem have already taken effect.
    std::vector<DeclResult> check(std::string_view source);

    /// Like `check`, but calls `sink` with each result as soon as it is known.
    template <class Sink>
    void check(std::string_view source, Sink&& sink) {
        check_each(source, [&](DeclResult&& r) { sink(std::move(r)); });
    }

private:
    struct Impl;
    void check_each(std::string_view source, const std::function<void(DeclResult&&)>& sink);
    std::unique_ptr<Impl> impl_;
};

}  // namespace typeinfer
