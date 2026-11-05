/**
 * Running work on a thread with a large stack.
 *
 * Parsing, inference and printing recurse once per level of expression or
 * type nesting, which can reach thousands of levels.
 */
module typeinfer.stack;

import core.thread : Thread;

/// Default stack size for `runWithLargeStack`: 1 GiB of address space.
enum size_t defaultStackBytes = size_t(1) << 30;

/**
 * Run `work` to completion on a new thread with a stack of `stackBytes`
 * bytes, and rethrow anything it throws on the calling thread.
 */
void runWithLargeStack(scope void delegate() work, size_t stackBytes = defaultStackBytes)
{
    Throwable failure;
    auto thread = new Thread(() {
        try
            work();
        catch (Throwable t)
            failure = t;
    }, stackBytes);
    thread.start();
    thread.join(false);
    if (failure !is null)
        throw failure;
}
