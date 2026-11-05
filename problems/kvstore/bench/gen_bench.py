#!/usr/bin/env python3
"""Deterministic performance-benchmark generator for kvstore (Tessera).

Writes three directory-mode cases next to this file, in the same layout as
``tests/`` (``NNN_name/input/`` and ``NNN_name/expected/``), so that

    python3 run_tests.py kvstore --tests-dir problems/kvstore/bench -- <run.sh>

scores an implementation on them. Expected outputs come from the reference
implementation, driven in process exactly as ``gen_tests.py`` drives it.

Run as ``python3 bench/gen_bench.py`` from ``problems/kvstore/``.
"""

import os
import random
import shutil
import sys

sys.dont_write_bytecode = True  # keep problems/kvstore free of caches
BENCH = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(BENCH))

import gen_tests  # noqa: E402
from gen_tests import S, build, gen_workload, run_ref  # noqa: E402

CITIES = ["austin", "berlin", "cairo", "delhi", "lima", "lyon", "madrid",
          "nairobi", "osaka", "oslo", "paris", "perth", "quito", "rome",
          "seoul", "sydney", "tokyo", "turin", "vienna", "zurich"]
TAGS = ["admin", "beta", "dev", "ops", "qa", "sales", "staff", "vip"]
FIRST = ["ada", "alan", "barbara", "claude", "dennis", "edsger", "frances",
         "grace", "john", "ken", "linus", "margaret", "niklaus", "radia",
         "tony", "barbara", "donald", "leslie", "robin", "shafi"]


def user_doc(rnd, uid, bio_prob=0.015):
    """A user record: mostly inline-sized, occasionally with a long bio."""
    fields = [
        'id:%d' % uid,
        'name:"%s%d"' % (rnd.choice(FIRST), rnd.randrange(1000)),
        'age:%d' % rnd.randint(18, 80),
        'city:"%s"' % rnd.choice(CITIES),
        'score:%d' % rnd.randint(0, 100000),
        'active:%s' % rnd.choice(["true", "false"]),
    ]
    if rnd.random() < 0.6:
        fields.append('tags:[%s]' % ",".join(
            '"%s"' % t for t in rnd.sample(TAGS, rnd.randint(1, 3))))
    if rnd.random() < 0.3:
        fields.append('addr:{zip:%d,street:"s%d"}' % (
            rnd.randint(10000, 99999), rnd.randrange(500)))
    if rnd.random() < bio_prob:
        fields.append('bio:"%s"' % ("lorem ipsum " * rnd.randint(20, 400)))
    return "{" + ",".join(fields) + "}"


def ukey(i):
    return "user:%07d" % i


# --------------------------------------------------------------------------
# 001: bulk ingest
# --------------------------------------------------------------------------

def bulk_ingest(n_users=22000, batch=250, seed=9001, rewrite_batches=40):
    """Batched loading of user records in random key order, with reads."""
    rnd = random.Random(seed)
    ids = list(range(n_users))
    rnd.shuffle(ids)
    lines = []
    loaded = []
    i = 0
    while i < len(ids):
        if rnd.random() < 0.85:
            size = rnd.randint(batch // 2, batch * 3 // 2)
            lines.append("begin")
            chunk = ids[i:i + size]
            for uid in chunk:
                lines.append('put "%s" %s' % (ukey(uid), user_doc(rnd, uid)))
            lines.append("commit")
        else:
            chunk = ids[i:i + rnd.randint(5, 40)]
            for uid in chunk:
                lines.append('put "%s" %s' % (ukey(uid), user_doc(rnd, uid)))
        i += len(chunk)
        loaded.extend(chunk)
        # Read-back traffic interleaved with the load.
        for _ in range(rnd.randint(2, 8)):
            lines.append('get "%s"' % ukey(rnd.choice(loaded)))
        if rnd.random() < 0.3:
            lines.append('scan from "%s" limit %d keys'
                         % (ukey(rnd.choice(loaded)), rnd.randint(5, 50)))
        if rnd.random() < 0.05:
            lines.append("stat")
    # Re-writes of existing records (replacements) in batches.
    for _ in range(rewrite_batches):
        lines.append("begin")
        for _ in range(rnd.randint(100, 300)):
            uid = rnd.randrange(n_users)
            lines.append('put "%s" %s' % (ukey(uid), user_doc(rnd, uid)))
        lines.append("commit")
    lines.append("checkpoint")
    lines.append("stat")
    lines.append('scan from "user:0012345" to "user:0012400"')
    lines.append("scan reverse limit 20 keys")
    lines.append("scan keys limit 20")
    return S(*lines)


# --------------------------------------------------------------------------
# 002: secondary indexes, queries and deletes on a populated store
# --------------------------------------------------------------------------

def populate(n_users, seed):
    rnd = random.Random(seed)
    ids = list(range(n_users))
    rnd.shuffle(ids)
    lines = []
    for j in range(0, n_users, 500):
        lines.append("begin")
        for uid in ids[j:j + 500]:
            lines.append('put "%s" %s' % (ukey(uid), user_doc(rnd, uid)))
        lines.append("commit")
    lines.append("checkpoint")
    return S(*lines)


def rnd_pred(rnd):
    leaves = [
        lambda: 'city == "%s"' % rnd.choice(CITIES),
        lambda: 'age %s %d' % (rnd.choice(["<", "<=", ">", ">="]),
                               rnd.randint(18, 80)),
        lambda: 'score %s %d' % (rnd.choice(["<", ">="]),
                                 rnd.randint(0, 100000)),
        lambda: 'age == %d' % rnd.randint(18, 80),
        lambda: 'active == %s' % rnd.choice(["true", "false"]),
        lambda: 'addr.zip >= %d' % rnd.randint(10000, 99999),
        lambda: 'name == "%s%d"' % (rnd.choice(FIRST), rnd.randrange(1000)),
    ]
    # Most queries lead with an indexed field (the first four leaves); the
    # unindexed ones mostly narrow an indexed lookup.
    pred = rnd.choice(leaves[:4] if rnd.random() < 0.95 else leaves[4:])()
    for _ in range(rnd.choice([0, 1, 1, 2])):
        pred += " and " + rnd.choice(leaves)()
    r = rnd.random()
    if r < 0.1:
        pred = "exists bio and " + pred
    elif r < 0.2:
        pred = "(%s) or %s" % (pred, rnd.choice(leaves)())
    elif r < 0.25:
        pred = "not(%s) and %s" % (rnd.choice(leaves)(), pred)
    return pred


def index_queries(n_users=12000, n_ops=1800, seed=9002):
    """Index builds, indexed and unindexed finds, and index maintenance."""
    rnd = random.Random(seed)
    alive = set(range(n_users))
    lines = ["stat", "create index city", "create index age",
             "create index score", "create index addr.zip", "indexes"]
    for k in range(n_ops):
        r = rnd.random()
        if r < 0.40:
            lines.append("find %s limit %d" % (rnd_pred(rnd), rnd.randint(1, 10)))
        elif r < 0.56:
            uid = rnd.randrange(n_users)
            field, val = rnd.choice([
                ("age", str(rnd.randint(18, 80))),
                ("city", '"%s"' % rnd.choice(CITIES)),
                ("score", str(rnd.randint(0, 100000))),
                ("addr.zip", str(rnd.randint(10000, 99999))),
                ("active", rnd.choice(["true", "false"]))])
            lines.append('update "%s" %s %s' % (ukey(uid), field, val))
        elif r < 0.62:
            # Range deletes: a run of neighbouring keys, which empties leaves
            # and drives borrow/merge in the primary and index trees.
            start = rnd.randrange(n_users)
            lines.append("begin")
            for uid in range(start, min(n_users, start + rnd.randint(10, 40))):
                if uid in alive:
                    lines.append('delete "%s"' % ukey(uid))
                    alive.discard(uid)
            lines.append("commit")
        elif r < 0.72:
            uid = rnd.randrange(n_users)
            alive.add(uid)
            lines.append('put "%s" %s' % (ukey(uid), user_doc(rnd, uid)))
        elif r < 0.80:
            lines.append('unset "%s" %s' % (ukey(rnd.randrange(n_users)),
                                            rnd.choice(["tags", "addr", "age"])))
        elif r < 0.90:
            lines.append('get "%s"' % ukey(rnd.randrange(n_users)))
        elif r < 0.96:
            lines.append('scan from "%s" limit %d keys'
                         % (ukey(rnd.randrange(n_users)), rnd.randint(1, 30)))
        else:
            lines.append("stat")
        if k % 1500 == 750:
            lines.append("drop index age")
            lines.append("create index name")
            lines.append("find age >= 40 and city == \"oslo\" limit 5")
            lines.append("drop index name")
            lines.append("create index age")
    lines.append("indexes")
    lines.append("stat")
    return S(*lines)


# --------------------------------------------------------------------------
# 003: mixed workload after crash recovery
# --------------------------------------------------------------------------

def mixed_recovery(seed=9003, n_cmds=25000):
    """Recover a cut log, then run the random mixed workload at scale."""
    first = gen_workload(seed, 20000, 6000, (4, 5, 2, 1, 0),
                         True, True, True, 6)
    # Commits after the last checkpoint, so the cut log has work to replay.
    tail = S(*('put "k%05d" %s' % (i * 37 % 6000, gen_tests.listdoc(5 + i % 20))
               for i in range(90)))
    tdb, twal = build(first + tail)
    cut = 32 + (len(twal) - 32) * 3 // 4
    second = gen_workload(seed + 1, n_cmds, 6000, (4, 5, 2, 1, 0),
                          True, True, True, 6)
    return second, tdb, twal[:cut]


def write_case(name, commands, tdb=None, twal=None, root=BENCH):
    d = os.path.join(root, name)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(os.path.join(d, "input"))
    os.makedirs(os.path.join(d, "expected"))
    with open(os.path.join(d, "input", "commands.txt"), "wb") as f:
        f.write(commands.encode("utf-8"))
    if tdb is not None:
        with open(os.path.join(d, "input", "main.tdb"), "wb") as f:
            f.write(tdb)
    if twal is not None:
        with open(os.path.join(d, "input", "main.twal"), "wb") as f:
            f.write(twal)
    results, out_tdb, out_twal = run_ref(commands, tdb, twal)
    for fn, data in (("results.txt", results.encode("utf-8")),
                     ("main.tdb", out_tdb), ("main.twal", out_twal)):
        with open(os.path.join(d, "expected", fn), "wb") as f:
            f.write(data)
    print("wrote %s: %d command lines" % (name, commands.count("\n")),
          flush=True)


# Long tier (--long, written to ../bench-long): the same three workloads with
# more rewrite batches, a larger store with more index operations, and a
# longer mixed script after recovery.
LONG_INGEST = dict(n_users=44000, rewrite_batches=2800)
LONG_INDEX_USERS = 40000
LONG_INDEX_OPS = 5200
LONG_MIXED_CMDS = 170000


def main_long(only):
    root = os.path.join(os.path.dirname(BENCH), "bench-long")
    os.makedirs(root, exist_ok=True)

    def want(n):
        return not only or n in only

    if want("001"):
        write_case("001_bulk_ingest", bulk_ingest(**LONG_INGEST), root=root)
    if want("002"):
        tdb, twal = build(populate(LONG_INDEX_USERS, 9102))
        write_case("002_index_queries", index_queries(LONG_INDEX_USERS, LONG_INDEX_OPS),
                   tdb, twal, root=root)
    if want("003"):
        cmds, tdb, twal = mixed_recovery(n_cmds=LONG_MIXED_CMDS)
        write_case("003_mixed_recovery", cmds, tdb, twal, root=root)
    return 0


def main(argv):
    only = set(a for a in argv[1:] if a != "--long")
    if "--long" in argv[1:]:
        return main_long(only)

    def want(n):
        return not only or n in only

    if want("001"):
        write_case("001_bulk_ingest", bulk_ingest())
    if want("002"):
        tdb, twal = build(populate(12000, 9102))
        write_case("002_index_queries", index_queries(), tdb, twal)
    if want("003"):
        cmds, tdb, twal = mixed_recovery()
        write_case("003_mixed_recovery", cmds, tdb, twal)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
