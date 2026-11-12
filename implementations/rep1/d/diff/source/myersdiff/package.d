/**
 * Exact, linear-space Myers diff and patch for line-oriented text.
 *
 * Import this package to get the whole public API:
 *
 * $(UL
 *   $(LI $(MODULE myersdiff.edit)     — `Edit`, `EditKind`, `cost`)
 *   $(LI $(MODULE myersdiff.intern)   — `Interner`, `internLines`)
 *   $(LI $(MODULE myersdiff.myers)    — `diffIds`, `diffLines`)
 *   $(LI $(MODULE myersdiff.script)   — `writeScript`, `parseScript`, `ScriptLine`)
 *   $(LI $(MODULE myersdiff.patch)    — `applyScript`, `PatchException`)
 *   $(LI $(MODULE myersdiff.parse)    — `parseRequest`, `Request`, `ParseException`)
 *   $(LI $(MODULE myersdiff.protocol) — `process`, the whole stdin→stdout contract)
 * )
 */
module myersdiff;

public import myersdiff.edit;
public import myersdiff.intern;
public import myersdiff.myers;
public import myersdiff.script;
public import myersdiff.patch;
public import myersdiff.parse;
public import myersdiff.protocol;
