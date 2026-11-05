/**
 * Kiln: an incremental build system that evaluates build files written in
 * the Kiln Build Language (KBL) and simulates their execution on parallel
 * workers against a virtual file system.
 *
 * Most users need only `Vfs`, `runBuild` and, for scripted sessions,
 * `parseSession` / `runSession`.
 */
module kiln;

public import kiln.build;
public import kiln.errors;
public import kiln.session;
public import kiln.vfs;
