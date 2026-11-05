/// minisql: a small in-memory relational database for a subset of SQL.
///
/// The usual entry point is `Database`:
/// ---
/// import minisql;
///
/// auto db = new Database;
/// db.run("CREATE TABLE t (a INTEGER, b TEXT);");
/// db.run("INSERT INTO t VALUES (1, 'x'), (2, 'y');");
/// auto res = db.execute("SELECT b FROM t WHERE a > 1");
/// assert(res.rowCount == 1 && res.row(0)[0].str == "y");
/// ---
///
/// The pipeline is split into modules by responsibility: `minisql.lexer`,
/// `minisql.parser` (syntax trees in `minisql.ast`), `minisql.binder` (bound
/// trees in `minisql.plan`), `minisql.executor` (using `minisql.eval`,
/// `minisql.like` and `minisql.keytable`), and `minisql.database` on top.
module minisql;

public import minisql.database;
public import minisql.errors;
public import minisql.result;
public import minisql.table;
public import minisql.value;
