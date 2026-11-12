/**
 * sqlitefile — read SQLite 3 database files byte by byte, with a tiny query
 * engine on top.
 *
 * The library is split by responsibility:
 *
 * $(UL
 *   $(LI `sqlitefile.database` — the pager: file bytes, header, pages)
 *   $(LI `sqlitefile.btree` — B-tree pages, overflow chains, tree walks)
 *   $(LI `sqlitefile.record` — record (row / index entry) decoding)
 *   $(LI `sqlitefile.value`, `sqlitefile.affinity`, `sqlitefile.numeric`,
 *        `sqlitefile.render` — values, ordering, affinity, printing)
 *   $(LI `sqlitefile.ddl`, `sqlitefile.schema` — `CREATE` statement parsing and the catalog)
 *   $(LI `sqlitefile.query`, `sqlitefile.engine` — the query language and its executor)
 * )
 *
 * Example:
 * ---
 * import sqlitefile;
 * auto db = Database.open("people.sqlite");
 * auto engine = new Engine(db);
 * auto output = engine.execute("SELECT name FROM people WHERE age > 40");
 * ---
 */
module sqlitefile;

public import sqlitefile.affinity;
public import sqlitefile.btree;
public import sqlitefile.database;
public import sqlitefile.ddl;
public import sqlitefile.engine;
public import sqlitefile.errors;
public import sqlitefile.numeric;
public import sqlitefile.query;
public import sqlitefile.record;
public import sqlitefile.render;
public import sqlitefile.schema;
public import sqlitefile.value;
