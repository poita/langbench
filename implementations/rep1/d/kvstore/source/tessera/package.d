/// Tessera: an embedded, single-file transactional document store with a
/// write-ahead log, a B+tree primary index, overflow pages, secondary indexes,
/// crash recovery and a small command language.
///
/// Import `tessera` for the public API: `Database` for programmatic use,
/// `Interpreter` for the command language, `Value` for documents.
module tessera;

public import tessera.ast;
public import tessera.constants;
public import tessera.crc : crc32;
public import tessera.database;
public import tessera.errors;
public import tessera.interpreter;
public import tessera.parser : parseCommand;
public import tessera.render : renderValue, renderToString;
public import tessera.value;
