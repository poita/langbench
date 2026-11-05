/**
 * mdiff: exact Myers diff and patch for line-oriented text.
 *
 * Import this package for the whole public API:
 * $(UL
 *   $(LI $(MREF mdiff, diff): `diffLines`, the main entry point.)
 *   $(LI $(MREF mdiff, patch): `applyScript`.)
 *   $(LI $(MREF mdiff, script): render an edit script as text.)
 *   $(LI $(MREF mdiff, myers): the algorithm on integer id sequences.)
 *   $(LI $(MREF mdiff, intern): line interning.)
 *   $(LI $(MREF mdiff, lines): zero-copy line reader.)
 *   $(LI $(MREF mdiff, protocol): the CLI's stdin/stdout protocol.)
 * )
 */
module mdiff;

public import mdiff.diff;
public import mdiff.edit;
public import mdiff.errors;
public import mdiff.intern;
public import mdiff.lines;
public import mdiff.myers;
public import mdiff.patch;
public import mdiff.protocol;
public import mdiff.script;
