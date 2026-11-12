/**
 * Kiln — an incremental build system over a virtual file system.
 *
 * Kiln evaluates build files written in the Kiln Build Language (KBL) into a
 * graph of steps, decides which are out of date from content hashes recorded in
 * `.kiln-state`, and executes those on a deterministic simulation of parallel
 * workers. Nothing runs in a real shell: the sixteen built-in commands are
 * implemented by the engine.
 *
 * Typical use:
 * ---
 * import kiln;
 *
 * auto ws = new Workspace;
 * ws.write("main.kiln", "step { out \"out/a.txt\"\n cmd write(\"hi\\n\") }\n...");
 * auto report = runBuild(ws, [], 2);
 * ---
 *
 * Module overview:
 * $(UL
 *   $(LI `kiln.workspace` — the virtual file system, path rules and glob index)
 *   $(LI `kiln.lexer`, `kiln.parser`, `kiln.ast` — KBL syntax)
 *   $(LI `kiln.value`, `kiln.builtins`, `kiln.glob`, `kiln.eval` — KBL semantics)
 *   $(LI `kiln.model`, `kiln.commands`, `kiln.graph` — steps, commands and the dependency graph)
 *   $(LI `kiln.state`, `kiln.scheduler`, `kiln.build` — change detection and execution)
 *   $(LI `kiln.session` — session scripts and the log)
 * )
 */
module kiln;

public import kiln.build;
public import kiln.errors;
public import kiln.eval : Interpreter, mainBuildFile;
public import kiln.graph : Graph;
public import kiln.hash;
public import kiln.model;
public import kiln.scheduler : Event, EventKind;
public import kiln.session;
public import kiln.value : Value, ValueType;
public import kiln.workspace;
