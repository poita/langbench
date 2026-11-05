/// gitrepo: read a git repository straight off disk.
///
/// Importing `gitrepo` brings in the whole public API:
///
/// ---
/// import gitrepo;
///
/// auto repo = new Repository("project/.git");
/// ObjectId head = repo.revParse("HEAD~1");
/// foreach (entry; repo.log(head, 5))
///     writeln(entry.id, " ", entry.commit.subject);
/// ---
module gitrepo;

public import gitrepo.batch;
public import gitrepo.delta;
public import gitrepo.errors;
public import gitrepo.inflate;
public import gitrepo.objects;
public import gitrepo.odb;
public import gitrepo.oid;
public import gitrepo.pack;
public import gitrepo.queries;
public import gitrepo.quote;
public import gitrepo.refs;
public import gitrepo.repository;
public import gitrepo.revision;
public import gitrepo.sha1;
