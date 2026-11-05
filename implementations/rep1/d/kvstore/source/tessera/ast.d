/// Parsed form of commands and predicates.
module tessera.ast;

import tessera.lexer : CmpOp;
import tessera.value;

/// The fifteen commands.
enum CommandKind
{
    begin,
    commit,
    rollback,
    checkpoint,
    stat,
    indexes,
    put,
    get,
    delete_,
    update,
    unset,
    scan,
    find,
    createIndex,
    dropIndex,
}

/// Options of a `scan` command.
struct ScanOptions
{
    /// Inclusive lower bound, when `hasFrom`.
    bool hasFrom;
    string from;
    /// Exclusive upper bound, when `hasTo`.
    bool hasTo;
    string to;
    /// Maximum number of results, when `hasLimit`.
    bool hasLimit;
    long limit;
    /// Emit in descending key order.
    bool reverse;
    /// Emit only keys.
    bool keysOnly;
}

/// Node kinds of a predicate tree.
enum PredKind
{
    and,
    or,
    not,
    exists,
    missing,
    compare,
}

/// A node of a predicate tree.
final class Pred
{
    PredKind kind;
    /// Children: two for `and`/`or`, one for `not`.
    Pred[] kids;
    /// Field path of `exists`, `missing` and `compare`.
    string[] path;
    /// Operator and right-hand side of `compare`.
    CmpOp op;
    Value rhs;

    this(PredKind kind) pure nothrow @safe { this.kind = kind; }

    /// The path text (segments joined by `.`).
    string pathText() const pure nothrow @safe { return joinPath(path); }
}

/// Join path segments with `.`.
string joinPath(const string[] segs) pure nothrow @safe
{
    string r;
    foreach (i, s; segs)
    {
        if (i)
            r ~= '.';
        r ~= s;
    }
    return r;
}

/// A parsed command line.
struct Command
{
    CommandKind kind;
    /// Key argument of put/get/delete/update/unset.
    string key;
    /// Path argument of update/unset/create index/drop index.
    string[] path;
    /// Document of put, value of update.
    Value value;
    /// Options of scan.
    ScanOptions scan;
    /// Predicate of find.
    Pred pred;
    /// `limit` of find.
    bool hasLimit;
    long limit;
}
