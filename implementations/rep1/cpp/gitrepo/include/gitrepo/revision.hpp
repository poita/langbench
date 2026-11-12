// Revision syntax: names, abbreviations, `^`, `~` and `^{...}`.
#pragma once

#include <string_view>

#include "gitrepo/object_id.hpp"
#include "gitrepo/repository.hpp"

namespace gitrepo {

/// What `peel` should turn an object into.
enum class PeelTarget {
  Any,     ///< `^{}`: strip tag objects only
  Commit,  ///< `^{commit}`
  Tree,    ///< `^{tree}`
  Blob,    ///< `^{blob}`
  Tag,     ///< `^{tag}`
};

/// Resolves a revision such as `main~2^2`, `v1.0^{tree}` or `1a2b3c4`.
/// Throws Error if it does not resolve. Only locates the object; it does not
/// verify its content (peeling does read the objects it passes through).
ObjectId resolve_revision(Repository& repo, std::string_view rev);

/// Peels `id` as `<rev>^{<target>}` does. Throws Error on failure.
ObjectId peel(Repository& repo, const ObjectId& id, PeelTarget target);

}  // namespace gitrepo
