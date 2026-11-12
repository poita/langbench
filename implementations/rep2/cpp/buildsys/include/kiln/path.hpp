// Workspace path and name validation.
#pragma once

#include <string_view>

namespace kiln {

/// True if `s` is a valid workspace path (see SPEC "Workspace paths").
bool isWorkspacePath(std::string_view s) noexcept;

/// True if `s` matches `[A-Za-z_][A-Za-z0-9_]*`.
bool isIdentifier(std::string_view s) noexcept;

/// True if `s` is `@` followed by an identifier-shaped name.
bool isPhonyRef(std::string_view s) noexcept;

/// True if the first component of `path` is exactly `out`.
bool isGeneratedPath(std::string_view path) noexcept;

}  // namespace kiln
