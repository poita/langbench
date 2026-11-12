mod common;

use common::*;
use gitrepo::{rev, ObjectId};

/// The worked example of the specification: two commits, one blob.
#[test]
fn worked_example() {
    let r = TestRepo::new();
    let empty = r.tree(&[]);
    let blob = r.blob("one file\n");
    assert_eq!(blob.to_hex(), "b7814cae2e925fe74c6cd5816462fff515ccb256");
    let tree = r.tree(&[("100644", b"only.txt", blob)]);
    let c1 = r.commit(empty, &[], 1_400_000_000, "Empty tree commit");
    let c2 = r.commit(tree, &[c1], 1_400_003_600, "Add only.txt");
    r.set_ref("refs/heads/main", &c2);
    r.write_file("HEAD", format!("{c1}\n").as_bytes());
    let repo = r.open();

    assert_eq!(run(&repo, "count-objects").unwrap(), "loose: 5\nin-pack: 0\npacks: 0\n");
    assert_eq!(run(&repo, "rev-parse HEAD").unwrap(), format!("{c1}\n"));
    assert_eq!(run(&repo, "rev-parse main^").unwrap(), format!("{c1}\n"));
    assert_eq!(
        run(&repo, "log main").unwrap(),
        format!(
            "{c2} Ada Lovelace 1400003600 Add only.txt\n{c1} Ada Lovelace 1400000000 Empty tree commit\n"
        )
    );
    assert_eq!(run(&repo, "log main 0").unwrap(), "");
    assert_eq!(run(&repo, "ls-tree main").unwrap(), format!("100644 blob {blob}\tonly.txt\n"));
    assert_eq!(run(&repo, "ls-tree HEAD").unwrap(), "");
    assert_eq!(run(&repo, &format!("cat-file {blob}")).unwrap(), "blob 9\none file\n");
    let zeros = "0".repeat(40);
    assert_eq!(
        run(&repo, "diff HEAD main").unwrap(),
        format!(":000000 100644 {zeros} {blob} A\tonly.txt\n")
    );
    assert_eq!(
        run(&repo, "diff main HEAD").unwrap(),
        format!(":100644 000000 {blob} {zeros} D\tonly.txt\n")
    );
}

#[test]
fn invalid_command_lines_fail() {
    let r = TestRepo::new();
    let t = r.tree(&[]);
    let c = r.commit(t, &[], 1, "x");
    r.set_ref("refs/heads/main", &c);
    let repo = r.open();
    for line in [
        "", "nonsense", "rev-parse", "rev-parse  main", "rev-parse main ", "ls-tree main ",
        "count-objects ", "count-objects x", "log main x", "log main -1", "log main 1 2",
        "cat-file", "diff main", "ls-tree main src", "ls-tree main .", "ls-tree main /",
    ] {
        assert!(run(&repo, line).is_none(), "{line:?} should fail");
    }
    assert!(run(&repo, "rev-parse main").is_some());
}

#[test]
fn revision_syntax() {
    let r = TestRepo::new();
    let t = r.tree(&[]);
    let a = r.commit(t, &[], 100, "a");
    let b = r.commit(t, &[a], 200, "b");
    let side = r.commit(t, &[a], 250, "side");
    let m = r.commit(t, &[b, side], 300, "merge");
    r.set_ref("refs/heads/main", &m);
    r.set_ref("refs/heads/side", &side);
    // Annotated tags: v1 -> m, v2 -> v1.
    let tag1 = r.loose("tag", format!("object {m}\ntype commit\ntag v1\n\nmsg\n").as_bytes());
    let tag2 = r.loose("tag", format!("object {tag1}\ntype tag\ntag v2\n\nmsg\n").as_bytes());
    r.set_ref("refs/tags/v1", &tag1);
    r.set_ref("refs/tags/v2", &tag2);
    r.write_file("HEAD", b"ref: refs/heads/main\n");
    r.write_file("refs/heads/alias", b"ref: refs/heads/side  \n");
    r.write_file("config", b"[core]\n");
    let repo = r.open();
    let rp = |s: &str| run(&repo, &format!("rev-parse {s}")).map(|o| o.trim().to_string());
    let hex = |id: &ObjectId| Some(id.to_hex());

    assert_eq!(rp("HEAD"), hex(&m));
    assert_eq!(rp("heads/main"), hex(&m));
    assert_eq!(rp("refs/heads/main"), hex(&m));
    assert_eq!(rp("alias"), hex(&side));
    assert_eq!(rp("main^"), hex(&b));
    assert_eq!(rp("main^1"), hex(&b));
    assert_eq!(rp("main^2"), hex(&side));
    assert_eq!(rp("main^3"), None);
    assert_eq!(rp("main^0"), hex(&m));
    assert_eq!(rp("main~2"), hex(&a));
    assert_eq!(rp("main~3"), None);
    assert_eq!(rp("main^2^"), hex(&a));
    assert_eq!(rp("main^^"), hex(&a));
    assert_eq!(rp("v2"), hex(&tag2));
    assert_eq!(rp("v2^{}"), hex(&m));
    assert_eq!(rp("v2^{commit}"), hex(&m));
    assert_eq!(rp("v2^{tag}"), hex(&tag2));
    assert_eq!(rp("v1^{tag}"), hex(&tag1));
    assert_eq!(rp("main^{tag}"), None);
    assert_eq!(rp("main^{blob}"), None);
    assert_eq!(rp("main^{object}"), hex(&m));
    assert_eq!(rp("main^{bogus}"), None);
    assert_eq!(rp("v2~1"), hex(&b));
    assert_eq!(rp("config"), None);
    assert_eq!(rp("../HEAD"), None);
    assert_eq!(rp("^{}"), None);
    // Abbreviations.
    assert_eq!(rp(&m.to_hex()[..8]), hex(&m));
    assert_eq!(rp(&m.to_hex()[..8].to_uppercase()), hex(&m));
    assert_eq!(rp(&m.to_hex()), hex(&m));
    assert_eq!(rp(&m.to_hex()[..3]), None);
    assert_eq!(rp(&"0".repeat(40)), None);
    assert_eq!(rp(&format!("{}^{{tree}}", &m.to_hex()[..10])), hex(&t));
    // The peeled tree of a tag.
    assert_eq!(run(&repo, "ls-tree v2").unwrap(), "");
    assert!(rev::resolve(&repo, b"main~1").is_ok());
}

#[test]
fn log_orders_by_committer_date() {
    let r = TestRepo::new();
    let t = r.tree(&[]);
    let root = r.commit(t, &[], 10, "root");
    let left = r.commit(t, &[root], 40, "left");
    let right = r.commit(t, &[root], 30, "right");
    let merge = r.commit(t, &[right, left], 50, "merge");
    let tie = r.commit(t, &[merge], 50, "tie");
    r.set_ref("refs/heads/main", &tie);
    let repo = r.open();
    let out = run(&repo, "log main").unwrap();
    let order: Vec<&str> = out.lines().map(|l| l.rsplit(' ').next().unwrap()).collect();
    assert_eq!(order, ["tie", "merge", "left", "right", "root"]);
    let limited = run(&repo, "log main 2").unwrap();
    assert_eq!(limited.lines().count(), 2);
    // A missing parent only matters when the walk gets there.
    let orphan = r.commit(t, &[ObjectId::from_bytes([9; 20])], 5, "orphan");
    r.set_ref("refs/heads/orphan", &orphan);
    let repo = r.open();
    assert!(run(&repo, "log orphan").is_none());
    assert_eq!(run(&repo, "log orphan 1").unwrap().lines().count(), 1);
}

#[test]
fn packed_refs_and_loose_precedence() {
    let r = TestRepo::new();
    let t = r.tree(&[]);
    let a = r.commit(t, &[], 1, "a");
    let b = r.commit(t, &[a], 2, "b");
    r.write_file(
        "packed-refs",
        format!("# pack-refs with: peeled\n{a} refs/heads/main\n{a} refs/tags/t\n^{b}\n{a} refs/heads/packed\n").as_bytes(),
    );
    r.set_ref("refs/heads/main", &b);
    let repo = r.open();
    assert_eq!(run(&repo, "rev-parse main").unwrap().trim(), b.to_hex());
    assert_eq!(run(&repo, "rev-parse packed").unwrap().trim(), a.to_hex());
    assert_eq!(run(&repo, "rev-parse t").unwrap().trim(), a.to_hex());
    // A ref may point at an object that does not exist.
    r.write_file("refs/heads/dangling", format!("{}\n", "ab".repeat(20)).as_bytes());
    let repo = r.open();
    assert_eq!(run(&repo, "rev-parse dangling").unwrap().trim(), "ab".repeat(20));
    assert!(run(&repo, "log dangling").is_none());
}

#[test]
fn symbolic_ref_depth_limit() {
    let r = TestRepo::new();
    let t = r.tree(&[]);
    let c = r.commit(t, &[], 1, "c");
    r.set_ref("refs/heads/r0", &c);
    for i in 1..=6 {
        r.write_file(&format!("refs/heads/r{i}"), format!("ref: refs/heads/r{}\n", i - 1).as_bytes());
    }
    let repo = r.open();
    assert!(run(&repo, "rev-parse r5").is_some()); // 5 follows
    assert!(run(&repo, "rev-parse r6").is_none()); // 6 follows
}

#[test]
fn diff_and_ls_tree_with_quoting() {
    let r = TestRepo::new();
    let f1 = r.blob("one\n");
    let f2 = r.blob("two\n");
    let sub1 = r.tree(&[("100644", b"a.txt", f1), ("100755", b"run", f1)]);
    let sub2 = r.tree(&[("100644", b"a.txt", f2), ("120000", b"run", f1)]);
    let sp1 = r.tree(&[("100644", "caf\u{e9}.txt".as_bytes(), f1)]);
    let sp2 = r.tree(&[("100644", b"quote\"and\\slash", f2)]);
    let t1 = r.tree(&[("40000", b"sub", sub1), ("40000", b"sp", sp1), ("160000", b"mod", f1)]);
    let t2 = r.tree(&[("40000", b"sub", sub2), ("40000", b"sp", sp2), ("160000", b"mod", f2)]);
    let c1 = r.commit(t1, &[], 1, "one");
    let c2 = r.commit(t2, &[c1], 2, "two");
    r.set_ref("refs/heads/a", &c1);
    r.set_ref("refs/heads/b", &c2);
    let repo = r.open();
    let out = run(&repo, "diff a b").unwrap();
    let expected = format!(
        ":160000 160000 {f1} {f2} M\tmod\n\
         :100644 000000 {f1} {z} D\t\"sp/caf\\303\\251.txt\"\n\
         :000000 100644 {z} {f2} A\t\"sp/quote\\\"and\\\\slash\"\n\
         :100644 100644 {f1} {f2} M\tsub/a.txt\n\
         :100755 120000 {f1} {f1} T\tsub/run\n",
        z = "0".repeat(40)
    );
    assert_eq!(out, expected);
    assert_eq!(run(&repo, "diff a a").unwrap(), "");
    assert_eq!(
        run(&repo, "ls-tree a sub").unwrap(),
        format!("100644 blob {f1}\ta.txt\n100755 blob {f1}\trun\n")
    );
    assert_eq!(
        run(&repo, "ls-tree b sp").unwrap(),
        format!("100644 blob {f2}\t\"quote\\\"and\\\\slash\"\n")
    );
    assert_eq!(
        run(&repo, "ls-tree a").unwrap(),
        format!("040000 tree {sub1}\tsub\n040000 tree {sp1}\tsp\n160000 commit {f1}\tmod\n")
    );
    assert!(run(&repo, "ls-tree a sub/a.txt").is_none());
    assert!(run(&repo, "ls-tree a sub//x").is_none());
    assert!(run(&repo, "ls-tree a nope").is_none());
    assert!(run(&repo, "diff a").is_none());
    assert!(run(&repo, &format!("diff a {f1}")).is_none());
}

#[test]
fn damaged_objects_fail_cat_file() {
    let r = TestRepo::new();
    let good = r.blob("good\n");
    // Content that does not hash to its id.
    let liar = ObjectId::from_bytes([0x11; 20]);
    r.write_raw_loose(&liar, &zlib_store(b"blob 4\nabc\n"));
    // Wrong declared size.
    let short = ObjectId::from_bytes([0x22; 20]);
    r.write_raw_loose(&short, &zlib_store(b"blob 9\nabc\n"));
    // Not zlib at all.
    let junk = ObjectId::from_bytes([0x33; 20]);
    r.write_raw_loose(&junk, b"this is not zlib");
    let repo = r.open();
    assert!(run(&repo, &format!("cat-file {good}")).is_some());
    for id in [liar, short, junk] {
        assert!(run(&repo, &format!("cat-file {id}")).is_none(), "{id}");
        // Present, so `^{object}` resolves without reading it.
        assert!(run(&repo, &format!("rev-parse {id}^{{object}}")).is_some());
    }
    assert!(run(&repo, "count-objects").unwrap().starts_with("loose: 4\n"));
}

#[test]
fn packs_with_deltas() {
    let r = TestRepo::new();
    let v1 = "line one\nline two\nline three\n".repeat(20);
    let v2 = format!("{v1}appended\n");
    let v3 = format!("{v2}and more\n");
    let id1 = gitrepo::sha1::hash_object("blob", v1.as_bytes());
    let id2 = gitrepo::sha1::hash_object("blob", v2.as_bytes());
    let id3 = gitrepo::sha1::hash_object("blob", v3.as_bytes());
    let loose_base = r.blob("loose base content, long enough to share a prefix\n");
    let ref_result = "loose base content, long enough to share a prefix\nplus a tail\n";
    let id4 = gitrepo::sha1::hash_object("blob", ref_result.as_bytes());
    let items = vec![
        PackItem::Base("blob", v1.clone().into_bytes()),
        PackItem::Ofs(0, make_delta(v1.as_bytes(), v2.as_bytes(), v1.len())),
        PackItem::Ofs(1, make_delta(v2.as_bytes(), v3.as_bytes(), 40)),
        PackItem::Ref(
            loose_base,
            make_delta(
                b"loose base content, long enough to share a prefix\n",
                ref_result.as_bytes(),
                20,
            ),
        ),
    ];
    r.pack("pack-test", &items, &[id1, id2, id3, id4]);
    // An index without a pack, and vice versa, is ignored.
    r.write_file("objects/pack/orphan.idx", b"junk");
    r.write_file("objects/pack/lonely.pack", b"PACK");
    let repo = r.open();
    for (id, text) in [(id1, &v1), (id2, &v2), (id3, &v3)] {
        assert_eq!(
            run(&repo, &format!("cat-file {id}")).unwrap(),
            format!("blob {}\n{text}", text.len())
        );
    }
    assert_eq!(
        run(&repo, &format!("cat-file {id4}")).unwrap(),
        format!("blob {}\n{ref_result}", ref_result.len())
    );
    assert_eq!(run(&repo, "count-objects").unwrap(), "loose: 1\nin-pack: 4\npacks: 1\n");
    assert_eq!(
        run(&repo, &format!("rev-parse {}", &id3.to_hex()[..6])).unwrap().trim(),
        id3.to_hex()
    );
}

#[test]
fn abbreviation_ambiguity() {
    let r = TestRepo::new();
    let a = ObjectId::from_bytes([0xab; 20]);
    let mut other = [0xab; 20];
    other[3] = 0xcd;
    let b = ObjectId::from_bytes(other);
    r.write_raw_loose(&a, &zlib_store(b"blob 1\nx"));
    r.write_raw_loose(&b, &zlib_store(b"blob 1\ny"));
    // The same id as `a` in a pack must not make `a` ambiguous with itself.
    r.pack("p", &[PackItem::Base("blob", b"x".to_vec())], &[a]);
    let repo = r.open();
    let rp = |s: &str| run(&repo, &format!("rev-parse {s}")).map(|o| o.trim().to_string());
    assert_eq!(rp("abab"), None); // both start with abababab / abababcd
    assert_eq!(rp("ababab"), None);
    assert_eq!(rp("abababa"), Some(a.to_hex()));
    assert_eq!(rp("abababc"), Some(b.to_hex()));
    assert_eq!(rp("ABABABAB"), Some(a.to_hex()));
    assert_eq!(rp("abababd"), None);
}

#[test]
fn loose_object_preferred_over_packed_copy() {
    let r = TestRepo::new();
    let content = "same id, two copies\n";
    let id = r.blob(content);
    // The packed copy holds different bytes under the same id.
    r.pack("p", &[PackItem::Base("blob", b"different".to_vec())], &[id]);
    let repo = r.open();
    assert_eq!(
        run(&repo, &format!("cat-file {id}")).unwrap(),
        format!("blob {}\n{content}", content.len())
    );
    assert_eq!(run(&repo, "count-objects").unwrap(), "loose: 1\nin-pack: 1\npacks: 1\n");
}

#[test]
fn library_api() {
    let r = TestRepo::new();
    let blob = r.blob("hello\n");
    let tree = r.tree(&[("100644", b"hello.txt", blob)]);
    let commit = r.commit(tree, &[], 42, "Say hello\n\nlonger body");
    r.set_ref("refs/heads/main", &commit);
    let repo = r.open();
    let id = rev::resolve(&repo, b"main").unwrap();
    let c = repo.commit(&id).unwrap();
    assert_eq!(c.subject(), b"Say hello");
    assert_eq!(c.author.timestamp, 42);
    let entries = repo.tree(&c.tree.unwrap()).unwrap();
    assert_eq!(entries[0].name, b"hello.txt");
    assert!(repo.read_verified(&blob).is_ok());
    assert!(gitrepo::Repository::open(&r.root.join("missing")).is_err());
}
