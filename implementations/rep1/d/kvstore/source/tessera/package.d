/// Tessera: an embedded, single-file transactional document store with a
/// write-ahead log, a B+tree primary index, overflow pages, secondary
/// indexes, crash recovery, checkpointing and a small command language.
///
/// The usual entry point is `Engine`: construct it from the bytes of
/// `main.tdb` and `main.twal` (either may be empty), run command lines, then
/// read the resulting file images back.
///
/// The lower layers are public too, split by responsibility:
/// $(UL
///   $(LI `tessera.value`: the document value model, serialisation, paths)
///   $(LI `tessera.node`, `tessera.btree`: canonical pages and the B+tree)
///   $(LI `tessera.pager`, `tessera.wal`, `tessera.recover`,
///        `tessera.checkpoint`: pages, log, recovery and checkpoints)
///   $(LI `tessera.lexer`, `tessera.parser`, `tessera.query`: the command language)
///   $(LI `tessera.engine`, `tessera.render`: execution and result blocks)
/// )
module tessera;

public import tessera.btree;
public import tessera.checkpoint;
public import tessera.constants;
public import tessera.crc;
public import tessera.engine;
public import tessera.errors;
public import tessera.header;
public import tessera.index;
public import tessera.lexer;
public import tessera.node;
public import tessera.overflow;
public import tessera.pager;
public import tessera.parser;
public import tessera.query;
public import tessera.recover;
public import tessera.render;
public import tessera.value;
public import tessera.wal;
