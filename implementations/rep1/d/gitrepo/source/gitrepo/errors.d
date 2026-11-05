/// Error type shared by every module of the library.
module gitrepo.errors;

/// Thrown when an object is missing or damaged, a revision cannot be resolved,
/// a command is malformed, or anything else prevents a query from being answered.
class GitError : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
