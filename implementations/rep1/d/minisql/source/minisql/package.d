/**
 * minisql — a small in-memory relational database for a subset of SQL.
 *
 * Import this module to get the whole public API:
 *
 * ---
 * import minisql;
 *
 * auto db = new Database;
 * string output = db.runScript("
 *     CREATE TABLE t (k INTEGER, v TEXT);
 *     INSERT INTO t VALUES (2, 'b'), (1, 'a');
 *     SELECT * FROM t ORDER BY k;
 * ");
 * assert(output == "1\ta\n2\tb\n-- 2 rows\n");
 * ---
 *
 * Modules, by responsibility:
 * $(UL
 *   $(LI `minisql.lexer` — tokens and statement splitting)
 *   $(LI `minisql.ast`, `minisql.parser` — syntax trees and the recursive-descent parser)
 *   $(LI `minisql.binder`, `minisql.expr` — name resolution and expression evaluation)
 *   $(LI `minisql.select` — SELECT execution (hash join, grouping, ordering))
 *   $(LI `minisql.database`, `minisql.table` — storage and statement execution)
 *   $(LI `minisql.value`, `minisql.like`, `minisql.errors` — values, LIKE matching, errors)
 * )
 */
module minisql;

public import minisql.database;
public import minisql.errors;
public import minisql.table;
public import minisql.value;
