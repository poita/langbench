/**
 * Kiln: an incremental build system that evaluates build files written in the
 * Kiln Build Language (KBL) into a step graph and executes the out-of-date
 * steps on a simulated set of parallel workers against a virtual file system.
 *
 * `import kiln;` brings in the public API:
 *
 * $(UL
 *   $(LI `kiln.vfs`: the virtual file system (`Vfs`).)
 *   $(LI `kiln.scheduler`: `runBuild`, a single build, and its `BuildResult`.)
 *   $(LI `kiln.session`: `parseSession` and `runSession`, scripted sessions and their log.)
 *   $(LI `kiln.fsio`: loading a workspace from disk and writing it back.)
 * )
 *
 * The lower layers (`kiln.lexer`, `kiln.parser`, `kiln.eval`, `kiln.graph`,
 * `kiln.commands`, `kiln.state`, ...) are importable on their own.
 */
module kiln;

public import kiln.errors;
public import kiln.fsio;
public import kiln.hash;
public import kiln.scheduler;
public import kiln.session;
public import kiln.vfs;
