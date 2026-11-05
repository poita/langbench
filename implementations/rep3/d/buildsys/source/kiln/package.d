/// Kiln: an incremental build system simulator.
///
/// Import `kiln` to get the whole public API. The pieces, by responsibility:
///
/// $(UL
///   $(LI `kiln.vfs` - the virtual file system and cached content hashes)
///   $(LI `kiln.lexer`, `kiln.parser`, `kiln.ast` - the KBL front end)
///   $(LI `kiln.interp`, `kiln.value`, `kiln.builtins`, `kiln.glob` - evaluation)
///   $(LI `kiln.plan`, `kiln.graph` - steps and the dependency graph)
///   $(LI `kiln.commands`, `kiln.state` - commands, the state file, freshness)
///   $(LI `kiln.build` - one build and the scheduler simulation)
///   $(LI `kiln.session` - session scripts and the log)
///   $(LI `kiln.fsio` - loading and writing real directories)
/// )
module kiln;

public import kiln.ast;
public import kiln.build;
public import kiln.bytes;
public import kiln.commands;
public import kiln.errors;
public import kiln.fsio;
public import kiln.glob;
public import kiln.graph;
public import kiln.hash;
public import kiln.interp;
public import kiln.lexer;
public import kiln.parser;
public import kiln.paths;
public import kiln.plan;
public import kiln.session;
public import kiln.state;
public import kiln.value;
public import kiln.vfs;
