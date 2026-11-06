/// sqlitefile: a from-scratch reader for SQLite 3 database files.
///
/// Import this module to get the whole public API:
///
/// ---
/// import sqlitefile;
///
/// auto db  = Database.open("people.sqlite");
/// auto cat = Catalog.load(db);
/// OutBuf out_;
/// execute(db, cat, parseQuery("SELECT name FROM people WHERE age > 40"), out_);
/// ---
module sqlitefile;

public import sqlitefile.affinity;
public import sqlitefile.btree;
public import sqlitefile.bytes;
public import sqlitefile.catalog;
public import sqlitefile.database;
public import sqlitefile.ddl;
public import sqlitefile.engine;
public import sqlitefile.errors;
public import sqlitefile.output;
public import sqlitefile.query;
public import sqlitefile.record;
public import sqlitefile.value;
