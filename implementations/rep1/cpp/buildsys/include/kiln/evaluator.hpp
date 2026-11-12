// Evaluation of KBL build files into a BuildDescription.
#pragma once

#include "kiln/step.hpp"
#include "kiln/vfs.hpp"

namespace kiln {

/// Runs `main.kiln` (following includes) against the workspace. Throws `Error`
/// with the first error in execution order, including `E_NO_BUILD_FILE`.
BuildDescription evaluate_workspace(const Vfs& vfs);

}  // namespace kiln
