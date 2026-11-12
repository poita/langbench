// Workspace path and name predicates.
#pragma once

#include <string_view>

namespace kiln {

/// Name of the persisted state file at the workspace root.
inline constexpr std::string_view kStateFile = ".kiln-state";

/// Name of the root build file.
inline constexpr std::string_view kRootBuildFile = "main.kiln";

/// `[A-Za-z_][A-Za-z0-9_]*`
bool is_identifier(std::string_view s) noexcept;

/// A valid workspace path: 1..1024 bytes, `/`-separated components of 1..255
/// bytes drawn from `[A-Za-z0-9_.+-]`, none of them `.` or `..`.
bool is_workspace_path(std::string_view s) noexcept;

/// `@` followed by an identifier-shaped name, or a workspace path.
bool is_reference_shape(std::string_view s) noexcept;

/// The text before the first `/` (the whole string if there is none).
std::string_view first_component(std::string_view path) noexcept;

/// True when the path's first component is exactly `out`.
bool is_generated_path(std::string_view path) noexcept;

}  // namespace kiln
