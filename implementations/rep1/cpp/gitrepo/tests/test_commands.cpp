#include <gtest/gtest.h>

#include "gitrepo/commands.hpp"
#include "gitrepo/repository.hpp"
#include "support.hpp"

using namespace gitrepo;
using namespace testing_support;

namespace {

const std::string kZero(40, '0');

struct Fixture {
  RepoBuilder b;
  ObjectId blob_a, blob_b, blob_c, sub, tree1, tree2, c1, c2, c3;
  std::unique_ptr<Repository> repo;

  Fixture() {
    blob_a = b.blob("a\n");
    blob_b = b.blob("b\n");
    blob_c = b.blob("c\n");
    sub = b.tree({{"100644", "deep.txt", blob_c}});
    tree1 = b.tree({{"100644", "a.txt", blob_a}, {"100644", "caf\xc3\xa9", blob_b}});
    tree2 = b.tree({{"100755", "a.txt", blob_a},
                    {"100644", "caf\xc3\xa9", blob_c},
                    {"40000", "dir", sub},
                    {"120000", "link", blob_b}});
    c1 = b.commit(tree1, {}, "First\n", 100);
    c2 = b.commit(tree2, {c1}, "\n\nSecond line one  \nline two\n\nbody\n", 200);
    c3 = b.commit(tree2, {c2, c1}, "", 150);  // older committer date than c2
    b.ref("HEAD", "ref: refs/heads/main\n");
    b.ref("refs/heads/main", c3.hex() + "\n");
    repo = std::make_unique<Repository>(b.git_dir());
  }

  std::string run(const std::string& line) { return run_command_or_error(*repo, line); }
};

}  // namespace

TEST(Commands, RevParse) {
  Fixture f;
  EXPECT_EQ(f.run("rev-parse main"), f.c3.hex() + "\n");
  EXPECT_EQ(f.run("rev-parse main^2"), f.c1.hex() + "\n");
  EXPECT_EQ(f.run("rev-parse nope"), "error\n");
  EXPECT_EQ(f.run("rev-parse"), "error\n");
  EXPECT_EQ(f.run("rev-parse  main"), "error\n");
  EXPECT_EQ(f.run("rev-parse main "), "error\n");
  EXPECT_EQ(f.run("rev-parse a b"), "error\n");
}

TEST(Commands, UnknownCommandsFail) {
  Fixture f;
  EXPECT_EQ(f.run("frobnicate"), "error\n");
  EXPECT_EQ(f.run(""), "error\n");
  EXPECT_EQ(f.run("Log main"), "error\n");
}

TEST(Commands, CountObjects) {
  Fixture f;
  EXPECT_EQ(f.run("count-objects"), "loose: 9\nin-pack: 0\npacks: 0\n");
  EXPECT_EQ(f.run("count-objects "), "error\n");
  EXPECT_EQ(f.run("count-objects x"), "error\n");
}

TEST(Commands, LogOrdersByCommitterDate) {
  Fixture f;
  // c3 (150) -> parents c2 (200), c1 (100); c2 is newer so comes first.
  EXPECT_EQ(f.run("log main"),
            f.c3.hex() + " Ada Lovelace 150 \n" +
                f.c2.hex() + " Ada Lovelace 200 Second line one line two\n" +
                f.c1.hex() + " Ada Lovelace 100 First\n");
  EXPECT_EQ(f.run("log main 1"), f.c3.hex() + " Ada Lovelace 150 \n");
  EXPECT_EQ(f.run("log main 0"), "");
  EXPECT_EQ(f.run("log main 99999999999999999999999").size(), f.run("log main").size());
  EXPECT_EQ(f.run("log main x"), "error\n");
  EXPECT_EQ(f.run("log main -1"), "error\n");
  EXPECT_EQ(f.run("log main "), "error\n");
  EXPECT_EQ(f.run("log main 1 2"), "error\n");
  EXPECT_EQ(f.run("log main^{tree}"), "error\n");
  EXPECT_EQ(f.run("log " + f.c1.hex()), f.c1.hex() + " Ada Lovelace 100 First\n");
}

TEST(Commands, LogFailsOnMissingParent) {
  RepoBuilder b;
  ObjectId tree = b.tree({});
  ObjectId missing = gitrepo::sha1("missing parent");
  ObjectId c = b.commit(tree, {missing}, "orphan\n", 10);
  b.ref("refs/heads/main", c.hex());
  Repository repo(b.git_dir());
  EXPECT_EQ(run_command_or_error(repo, "log main"), "error\n");
}

TEST(Commands, LsTree) {
  Fixture f;
  EXPECT_EQ(f.run("ls-tree main"),
            "100755 blob " + f.blob_a.hex() + "\ta.txt\n" +
                "100644 blob " + f.blob_c.hex() + "\t\"caf\\303\\251\"\n" +
                "040000 tree " + f.sub.hex() + "\tdir\n" +
                "120000 blob " + f.blob_b.hex() + "\tlink\n");
  EXPECT_EQ(f.run("ls-tree main dir"), "100644 blob " + f.blob_c.hex() + "\tdeep.txt\n");
  EXPECT_EQ(f.run("ls-tree " + f.tree2.hex() + " dir"), f.run("ls-tree main dir"));
  for (const std::string& bad : std::vector<std::string>{"ls-tree main a.txt", "ls-tree main missing", "ls-tree main dir/deep.txt",
                          "ls-tree main .", "ls-tree main dir/", "ls-tree main /dir",
                          "ls-tree main dir//x", "ls-tree main ", "ls-tree main ../dir",
                          "ls-tree " + f.blob_a.hex(), "ls-tree", "ls-tree a b c"}) {
    EXPECT_EQ(f.run(bad), "error\n") << bad;
  }
}

TEST(Commands, CatFileVerifiesHash) {
  Fixture f;
  EXPECT_EQ(f.run("cat-file " + f.blob_a.hex()), "blob 2\na\n");
  EXPECT_EQ(f.run("cat-file main^{tree}").substr(0, 8), "tree 128");

  // A loose object stored under the wrong id.
  ObjectId wrong = gitrepo::sha1("wrong");
  std::string hex = wrong.hex();
  write_file(f.b.git_dir() / "objects" / hex.substr(0, 2) / hex.substr(2),
             zlib_store(std::string("blob 3") + '\0' + "abc"));
  Repository repo(f.b.git_dir());
  EXPECT_EQ(run_command_or_error(repo, "cat-file " + hex), "error\n");
  EXPECT_EQ(run_command_or_error(repo, "rev-parse " + hex), hex + "\n");  // rev-parse does not read
  EXPECT_EQ(run_command_or_error(repo, "rev-parse " + hex + "^{object}"), hex + "\n");
}

TEST(Commands, Diff) {
  Fixture f;
  std::string expected =
      ":100644 100755 " + f.blob_a.hex() + " " + f.blob_a.hex() + " M\ta.txt\n" +
      ":100644 100644 " + f.blob_b.hex() + " " + f.blob_c.hex() + " M\t\"caf\\303\\251\"\n" +
      ":000000 100644 " + kZero + " " + f.blob_c.hex() + " A\tdir/deep.txt\n" +
      ":000000 120000 " + kZero + " " + f.blob_b.hex() + " A\tlink\n";
  EXPECT_EQ(f.run("diff " + f.c1.hex() + " main"), expected);
  EXPECT_EQ(f.run("diff main main"), "");
  std::string reverse = f.run("diff main " + f.c1.hex());
  EXPECT_NE(reverse.find(" D\tlink\n"), std::string::npos);
  EXPECT_NE(reverse.find(" D\tdir/deep.txt\n"), std::string::npos);
  EXPECT_EQ(f.run("diff main"), "error\n");
  EXPECT_EQ(f.run("diff main " + f.blob_a.hex()), "error\n");
}

TEST(Commands, DiffReportsTypeChanges) {
  RepoBuilder b;
  ObjectId blob = b.blob("x");
  ObjectId t1 = b.tree({{"100644", "f", blob}});
  ObjectId t2 = b.tree({{"120000", "f", blob}});
  b.ref("refs/heads/a", b.commit(t1, {}, "a\n", 1).hex());
  b.ref("refs/heads/b", b.commit(t2, {}, "b\n", 2).hex());
  Repository repo(b.git_dir());
  EXPECT_EQ(run_command_or_error(repo, "diff a b"),
            ":100644 120000 " + blob.hex() + " " + blob.hex() + " T\tf\n");
}

TEST(Commands, PackedHistoryMatchesLoose) {
  RepoBuilder b;
  PackBuilder pack;
  std::string text(300, 'z');
  ObjectId base = pack.add(ObjectType::Blob, text);
  ObjectId derived = pack.add_delta(base, text, "!", ObjectType::Blob, false);
  ObjectId tree = pack.add(ObjectType::Tree, RepoBuilder::tree_payload({{"100644", "f", derived}}));
  ObjectId commit = pack.add(ObjectType::Commit, RepoBuilder::commit_payload(tree, {}, "packed\n", 5, 5));
  pack.write(b.git_dir(), "pack-x");
  b.packed_refs(commit.hex() + " refs/heads/main\n");
  Repository repo(b.git_dir());
  EXPECT_EQ(run_command_or_error(repo, "count-objects"), "loose: 0\nin-pack: 4\npacks: 1\n");
  EXPECT_EQ(run_command_or_error(repo, "log main"), commit.hex() + " Ada Lovelace 5 packed\n");
  EXPECT_EQ(run_command_or_error(repo, "cat-file " + derived.hex()), "blob 301\n" + text + "!");
}
