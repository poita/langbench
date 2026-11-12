/// \file stack.hpp
/// Run code on a thread with a large native stack.
#pragma once

#include <cstddef>
#include <functional>

namespace scheme {

/// Default stack size used by the CLI (512 MiB of address space; pages are
/// committed only when touched).
constexpr std::size_t kDefaultStackBytes = std::size_t(512) << 20;

/// Run `fn` on a new thread with `bytes` of stack and wait for it. Exceptions
/// thrown by `fn` are rethrown in the caller. Falls back to calling `fn`
/// directly if the thread cannot be created.
void run_with_stack_size(std::size_t bytes, const std::function<void()>& fn);

}  // namespace scheme
