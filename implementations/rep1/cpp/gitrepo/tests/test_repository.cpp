#include <gtest/gtest.h>

#include "gitrepo/error.hpp"
#include "gitrepo/repository.hpp"
#include "gitrepo/revision.hpp"
#include "support.hpp"

using namespace gitrepo;
using namespace testing_support;

namespace {

/// Three commits (c1 <- c2 <- c3) on `main`, c2 also tagged.
struct Fixture {
  RepoBuilder b;
  ObjectId blob1, blob2, tree1, tree2, c1, c2, c3, annotated;

  Fixture() {
    blob1 = b.blob("one\n");
    blob2 = b.blob("two\n");
    tree1 = b.tree({{"100644", "a.txt", blob1}});
    tree2 = b.tree({{"100644", "a.txt", blob2}});
    c1 = b.commit(tree1, {}, "first\n", 1000);
    c2 = b.commit(tree2, {c1}, "second\n", 2000);
    c3 = b.commit(tree2, {c2}, "third\n", 3000);
    annotated = b.tag(c2, "commit", "v1");
    b.ref("HEAD", "ref: refs/heads/main\n");
    b.ref("refs/heads/main", c3.hex() + "\n");
    b.ref("refs/tags/v1", annotated.hex() + "\n");
  }
};

}  // namespace

TEST(Revisions, RefNamesAndSuffixes) {
  Fixture f;
  Repository repo(f.b.git_dir());
  EXPECT_EQ(resolve_revision(repo, "HEAD"), f.c3);
  EXPECT_EQ(resolve_revision(repo, "main"), f.c3);
  EXPECT_EQ(resolve_revision(repo, "refs/heads/main"), f.c3);
  EXPECT_EQ(resolve_revision(repo, "main^"), f.c2);
  EXPECT_EQ(resolve_revision(repo, "main~2"), f.c1);
  EXPECT_EQ(resolve_revision(repo, "main~0"), f.c3);
  EXPECT_EQ(resolve_revision(repo, "main^0"), f.c3);
  EXPECT_EQ(resolve_revision(repo, "main^^"), f.c1);
  EXPECT_EQ(resolve_revision(repo, "HEAD~1^1"), f.c1);
  EXPECT_THROW(resolve_revision(repo, "main~3"), Error);
  EXPECT_THROW(resolve_revision(repo, "main^2"), Error);
  EXPECT_THROW(resolve_revision(repo, "nosuch"), Error);
  EXPECT_THROW(resolve_revision(repo, ""), Error);
  EXPECT_THROW(resolve_revision(repo, "^"), Error);
  EXPECT_THROW(resolve_revision(repo, "~1"), Error);
}

TEST(Revisions, TagsAndPeeling) {
  Fixture f;
  Repository repo(f.b.git_dir());
  EXPECT_EQ(resolve_revision(repo, "v1"), f.annotated);
  EXPECT_EQ(resolve_revision(repo, "v1^{}"), f.c2);
  EXPECT_EQ(resolve_revision(repo, "v1^{commit}"), f.c2);
  EXPECT_EQ(resolve_revision(repo, "v1^{tag}"), f.annotated);
  EXPECT_EQ(resolve_revision(repo, "v1^{tree}"), f.tree2);
  EXPECT_EQ(resolve_revision(repo, "v1~1"), f.c1);
  EXPECT_EQ(resolve_revision(repo, "main^{tree}"), f.tree2);
  EXPECT_EQ(resolve_revision(repo, "main^{}"), f.c3);
  EXPECT_EQ(resolve_revision(repo, "main^{object}"), f.c3);
  EXPECT_THROW(resolve_revision(repo, "main^{blob}"), Error);
  EXPECT_THROW(resolve_revision(repo, "main^{tag}"), Error);
  EXPECT_THROW(resolve_revision(repo, "main^{bogus}"), Error);
  EXPECT_THROW(resolve_revision(repo, "main^{tree}^{commit}"), Error);
  EXPECT_THROW(resolve_revision(repo, "^{commit}"), Error);
}

TEST(Revisions, AbbreviatedIds) {
  Fixture f;
  Repository repo(f.b.git_dir());
  std::string hex = f.c3.hex();
  EXPECT_EQ(resolve_revision(repo, hex), f.c3);
  EXPECT_EQ(resolve_revision(repo, hex.substr(0, 7)), f.c3);
  std::string upper = hex.substr(0, 10);
  for (char& c : upper) c = static_cast<char>(std::toupper(c));
  EXPECT_EQ(resolve_revision(repo, upper), f.c3);
  EXPECT_EQ(resolve_revision(repo, hex.substr(0, 8) + "~1"), f.c2);
  EXPECT_THROW(resolve_revision(repo, hex.substr(0, 3)), Error);  // too short
  EXPECT_THROW(resolve_revision(repo, std::string(40, '0')), Error);  // absent
}

TEST(Revisions, AmbiguousPrefixFails) {
  RepoBuilder b;
  // Create objects until two share a 4-digit prefix.
  std::map<std::string, ObjectId> seen;
  std::string prefix;
  for (int i = 0; prefix.empty(); ++i) {
    ObjectId id = b.blob("blob " + std::to_string(i));
    auto [it, inserted] = seen.emplace(id.hex().substr(0, 4), id);
    if (!inserted) prefix = it->first;
  }
  Repository repo(b.git_dir());
  EXPECT_THROW(resolve_revision(repo, prefix), Error);
}

TEST(Revisions, NameLookupOrder) {
  Fixture f;
  f.b.ref("refs/heads/dup", f.c1.hex());
  f.b.ref("refs/tags/dup", f.c2.hex());
  f.b.ref("refs/remotes/origin/HEAD", "ref: refs/remotes/origin/main\n");
  f.b.ref("refs/remotes/origin/main", f.c1.hex());
  f.b.ref("refs/remotes/other/x", f.c2.hex());
  Repository repo(f.b.git_dir());
  EXPECT_EQ(resolve_revision(repo, "dup"), f.c2);                 // tags before heads
  EXPECT_EQ(resolve_revision(repo, "heads/dup"), f.c1);           // refs/<name>
  EXPECT_EQ(resolve_revision(repo, "origin"), f.c1);              // refs/remotes/<name>/HEAD
  EXPECT_EQ(resolve_revision(repo, "origin/main"), f.c1);         // refs/remotes/<name>
  EXPECT_EQ(resolve_revision(repo, "other/x"), f.c2);
}

TEST(Refs, SymbolicDepthAndBadNames) {
  Fixture f;
  f.b.ref("refs/heads/a1", "ref: refs/heads/a2\n");
  f.b.ref("refs/heads/a2", "ref: refs/heads/a3\n");
  f.b.ref("refs/heads/a3", "ref: refs/heads/a4\n");
  f.b.ref("refs/heads/a4", "ref: refs/heads/a5\n");
  f.b.ref("refs/heads/a5", "ref: refs/heads/a6\n");
  f.b.ref("refs/heads/a6", f.c1.hex() + "  \n");
  f.b.ref("refs/heads/b0", "ref: refs/heads/a1\n");
  f.b.ref("refs/heads/garbage", "not a ref\n");
  f.b.ref("config", f.c1.hex() + "\n");
  Repository repo(f.b.git_dir());
  EXPECT_EQ(resolve_revision(repo, "a1"), f.c1);   // 5 hops
  EXPECT_THROW(resolve_revision(repo, "b0"), Error);  // 6 hops
  EXPECT_THROW(resolve_revision(repo, "garbage"), Error);
  EXPECT_THROW(resolve_revision(repo, "config"), Error);
  EXPECT_THROW(resolve_revision(repo, "refs/heads/../heads/main"), Error);
  EXPECT_THROW(resolve_revision(repo, "refs//heads/main"), Error);
  EXPECT_THROW(resolve_revision(repo, "refs/heads/./main"), Error);
}

TEST(Refs, PackedRefsAndLooseOverride) {
  Fixture f;
  f.b.packed_refs("# pack-refs with: peeled\n" + f.c1.hex() + " refs/heads/packed\n^" + f.c2.hex() +
                  "\n" + f.c1.hex() + " refs/heads/main\n");
  Repository repo(f.b.git_dir());
  EXPECT_EQ(resolve_revision(repo, "packed"), f.c1);
  EXPECT_EQ(resolve_revision(repo, "main"), f.c3);  // loose file wins
}

TEST(Refs, RefToMissingObjectStillResolves) {
  Fixture f;
  f.b.ref("refs/heads/ghost", std::string(40, '1') + "\n");
  Repository repo(f.b.git_dir());
  EXPECT_EQ(resolve_revision(repo, "ghost").hex(), std::string(40, '1'));
  EXPECT_THROW(resolve_revision(repo, "ghost^{commit}"), Error);
  EXPECT_THROW(resolve_revision(repo, "ghost^{object}"), Error);
}

TEST(ObjectStore, LooseObjectsAndDamage) {
  RepoBuilder b;
  ObjectId id = b.blob("payload");
  // A loose file whose declared size is wrong.
  std::string bad_stored = std::string("blob 99") + '\0' + "short";
  ObjectId bad_id = gitrepo::sha1("some other id");
  std::string hex = bad_id.hex();
  write_file(b.git_dir() / "objects" / hex.substr(0, 2) / hex.substr(2), zlib_store(bad_stored));

  ObjectStore store(b.git_dir() / "objects");
  EXPECT_EQ(store.loose_count(), 2u);
  EXPECT_EQ(store.pack_count(), 0u);
  ObjectPtr o = store.read(id);
  EXPECT_EQ(o->type, ObjectType::Blob);
  EXPECT_EQ(o->data, "payload");
  EXPECT_TRUE(store.contains(bad_id));
  EXPECT_THROW(store.read(bad_id), Error);
  EXPECT_THROW(store.read(gitrepo::sha1("absent")), Error);
}

TEST(ObjectStore, PacksWithOfsAndRefDeltas) {
  RepoBuilder b;
  std::string base(500, 'x');
  PackBuilder pack;
  ObjectId base_id = pack.add(ObjectType::Blob, base);
  ObjectId ofs1 = pack.add_delta(base_id, base, "-one", ObjectType::Blob, false);
  ObjectId ofs2 = pack.add_delta(ofs1, base + "-one", "-two", ObjectType::Blob, false);
  ObjectId ref1 = pack.add_delta(ofs2, base + "-one-two", "-three", ObjectType::Blob, true);
  pack.write(b.git_dir(), "pack-test");

  ObjectStore store(b.git_dir() / "objects");
  EXPECT_EQ(store.pack_count(), 1u);
  EXPECT_EQ(store.packed_object_count(), 4u);
  EXPECT_EQ(store.loose_count(), 0u);
  EXPECT_EQ(store.read(base_id)->data, base);
  EXPECT_EQ(store.read(ofs1)->data, base + "-one");
  EXPECT_EQ(store.read(ofs2)->data, base + "-one-two");
  EXPECT_EQ(store.read(ref1)->data, base + "-one-two-three");
  EXPECT_EQ(store.read(ref1)->type, ObjectType::Blob);
  EXPECT_EQ(store.find_by_prefix(ref1.hex().substr(0, 6)).front(), ref1);
}

TEST(ObjectStore, LoosePreferredAndUnpairedPackIgnored) {
  RepoBuilder b;
  PackBuilder pack;
  ObjectId id = pack.add(ObjectType::Blob, "packed copy");
  pack.write(b.git_dir(), "pack-a");
  fs::remove(b.git_dir() / "objects" / "pack" / "pack-a.pack");  // idx without pack
  ObjectStore lonely(b.git_dir() / "objects");
  EXPECT_EQ(lonely.pack_count(), 0u);
  EXPECT_FALSE(lonely.contains(id));
}

TEST(Repository, CachesParsedObjects) {
  Fixture f;
  Repository repo(f.b.git_dir());
  const Commit& a = repo.commit(f.c3);
  const Commit& b = repo.commit(f.c3);
  EXPECT_EQ(&a, &b);
  EXPECT_EQ(a.subject, "third");
  EXPECT_THROW(repo.commit(f.tree1), Error);
  EXPECT_THROW(repo.tree(f.c1), Error);
  EXPECT_EQ(repo.tree(f.tree2).entries.size(), 1u);
}
