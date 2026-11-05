/// Error kinds raised by the command language and the engine.
module tessera.errors;

/// The kind of a failed command (the word printed after `error`).
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

/// The spelling of an error kind as it appears in `results.txt`.
string kindName(ErrorKind k) pure nothrow @nogc @safe
{
    final switch (k)
    {
    case ErrorKind.syntax: return "syntax";
    case ErrorKind.unknownCommand: return "unknown-command";
    case ErrorKind.badUtf8: return "bad-utf8";
    case ErrorKind.intRange: return "int-range";
    case ErrorKind.dupField: return "dup-field";
    case ErrorKind.depth: return "depth";
    case ErrorKind.badKey: return "bad-key";
    case ErrorKind.badPath: return "bad-path";
    case ErrorKind.notFound: return "not-found";
    case ErrorKind.noField: return "no-field";
    case ErrorKind.notObject: return "not-object";
    case ErrorKind.docTooLarge: return "doc-too-large";
    case ErrorKind.indexKeyTooLong: return "index-key-too-long";
    case ErrorKind.indexExists: return "index-exists";
    case ErrorKind.indexMissing: return "index-missing";
    case ErrorKind.indexLimit: return "index-limit";
    case ErrorKind.txnActive: return "txn-active";
    case ErrorKind.noTxn: return "no-txn";
    }
}

/// Thrown by every operation that can fail with a defined error kind.
class TesseraException : Exception
{
    /// What went wrong.
    ErrorKind kind;

    this(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(kindName(kind), file, line);
        this.kind = kind;
    }
}

/// Throw a `TesseraException` of the given kind.
noreturn fail(ErrorKind kind, string file = __FILE__, size_t line = __LINE__) pure @safe
{
    throw new TesseraException(kind, file, line);
}
