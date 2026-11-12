/// Error kinds raised by the command language and the engine (SPEC §18).
module tessera.errors;

/// Every way a command can fail. The spelling printed in `results.txt` is
/// given by `errorName`.
enum ErrorKind
{
    syntax,
    unknownCommand,
    badUtf8,
    intRange,
    dupField,
    depth,
    badKey,
    badPath,
    notFound,
    noField,
    notObject,
    docTooLarge,
    indexKeyTooLong,
    indexExists,
    indexMissing,
    indexLimit,
    txnActive,
    noTxn,
}

/// The name of an error kind as it appears after `error ` in a result block.
string errorName(ErrorKind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
    case ErrorKind.syntax:          return "syntax";
    case ErrorKind.unknownCommand:  return "unknown-command";
    case ErrorKind.badUtf8:         return "bad-utf8";
    case ErrorKind.intRange:        return "int-range";
    case ErrorKind.dupField:        return "dup-field";
    case ErrorKind.depth:           return "depth";
    case ErrorKind.badKey:          return "bad-key";
    case ErrorKind.badPath:         return "bad-path";
    case ErrorKind.notFound:        return "not-found";
    case ErrorKind.noField:         return "no-field";
    case ErrorKind.notObject:       return "not-object";
    case ErrorKind.docTooLarge:     return "doc-too-large";
    case ErrorKind.indexKeyTooLong: return "index-key-too-long";
    case ErrorKind.indexExists:     return "index-exists";
    case ErrorKind.indexMissing:    return "index-missing";
    case ErrorKind.indexLimit:      return "index-limit";
    case ErrorKind.txnActive:       return "txn-active";
    case ErrorKind.noTxn:           return "no-txn";
    }
}

/// Thrown when a command fails. A failing command never modifies the store.
class TesseraError : Exception
{
    /// What went wrong.
    ErrorKind kind;

    ///
    this(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        super(errorName(kind), file, line);
        this.kind = kind;
    }
}

/// Throw a `TesseraError` of the given kind.
noreturn fail(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) @safe pure
{
    throw new TesseraError(kind, file, line);
}
