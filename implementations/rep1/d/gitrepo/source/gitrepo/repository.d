/// A repository opened for reading.
module gitrepo.repository;

import gitrepo.errors;
import gitrepo.memo;
import gitrepo.objectid;
import gitrepo.objecttype;
import gitrepo.parse;
import gitrepo.refs;
import gitrepo.store;

/// A git repository (a `.git` directory or a bare repository), read straight
/// off disk. The object store, the refs and every parsed commit and tree are
/// loaded or computed at most once for the life of the object.
final class Repository
{
    private string dir_;
    private ObjectStore store_;
    private RefDb refs_;
    private Memo!Commit commits;
    private Memo!(TreeEntry[]) trees;
    private Memo!ObjectId tagTargets;

    /// Open the repository whose files live in `dir` (`HEAD`, `refs/`,
    /// `objects/`, `packed-refs`).
    this(string dir)
    {
        dir_ = dir;
        store_ = new ObjectStore(dir ~ "/objects");
        refs_ = new RefDb(dir);
    }

    /// The repository directory.
    string dir() const @safe pure nothrow @nogc
    {
        return dir_;
    }

    /// The object database.
    ObjectStore objects() @safe pure nothrow @nogc
    {
        return store_;
    }

    /// The reference database.
    RefDb refs() @safe pure nothrow @nogc
    {
        return refs_;
    }

    /// Loose / packed / pack counts, as printed by `count-objects`.
    ObjectCounts counts()
    {
        return store_.counts();
    }

    /// Read an object (cached). Throws `GitError` if missing or damaged.
    RawObject readObject(const ObjectId id)
    {
        return store_.read(id);
    }

    /// Read and parse a commit (cached). Throws `GitError` if the object is
    /// missing, damaged, or not a commit.
    Commit commit(const ObjectId id)
    {
        return commits.get(id, () {
            auto o = store_.read(id);
            if (o.type != ObjectType.commit)
                throw new GitError("not a commit: " ~ id.toString());
            return parseCommit(o.data);
        });
    }

    /// Read and parse a tree (cached). Throws `GitError` if the object is
    /// missing, damaged, or not a tree.
    const(TreeEntry)[] tree(const ObjectId id)
    {
        return trees.get(id, () {
            auto o = store_.read(id);
            if (o.type != ObjectType.tree)
                throw new GitError("not a tree: " ~ id.toString());
            return parseTree(o.data);
        });
    }

    /// The object a tag points at (cached). Throws `GitError` if `id` is not a
    /// readable tag.
    ObjectId tagTarget(const ObjectId id)
    {
        return tagTargets.get(id, () {
            auto o = store_.read(id);
            if (o.type != ObjectType.tag)
                throw new GitError("not a tag: " ~ id.toString());
            return parseTagTarget(o.data);
        });
    }
}
