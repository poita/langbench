/// Error type shared by every module of the library.
module gitrepo.errors;

/// Thrown whenever a repository operation cannot be carried out: a missing or
/// damaged object, an unresolvable revision, malformed input, ...
class GitError : Exception
{
    /// Create an error carrying `msg`.
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(msg, file, line);
    }
}
