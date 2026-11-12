// Package gitrepo reads a git repository straight off disk and answers
// queries about it, without invoking git or any git, zlib or SHA-1 library.
//
// The work is split by responsibility across packages:
//
//	gitrepo/sha1     SHA-1 (FIPS 180-4)
//	gitrepo/inflate  DEFLATE / zlib decoder
//	gitrepo/object   object types, ids, commit / tree / tag parsing
//	gitrepo/odb      loose objects, pack indexes, packfiles, deltas
//	gitrepo          refs, revision syntax and the queries (this package)
//	gitrepo/query    the textual command language used by the CLI
//
// Open a repository with [Open] and call its methods:
//
//	r, err := gitrepo.Open("/path/to/repo/.git")
//	id, err := r.RevParse("main~2")
//	entries, err := r.LsTree("HEAD", "src")
//
// Resolving a revision only locates an object; reading it is a separate step
// that can fail on a missing or damaged object. A Repo caches everything it
// reads, so each object is decoded at most once, and it is not safe for
// concurrent use.
package gitrepo
