#include <gtest/gtest.h>

#include <map>
#include <random>

#include "integrity.hpp"
#include "tessera/command.hpp"
#include "tessera/executor.hpp"

using namespace tessera;
using testing_util::check_integrity;

namespace {

Value V(const std::string& literal) { return parse_value_literal(literal); }

std::string big_doc(std::size_t serialised_len) {
  // A string document serialises to 5 + n bytes.
  return "\"" + std::string(serialised_len - 5, 'z') + "\"";
}

}  // namespace

TEST(Database, PutGetReplaceDelete) {
  Database db;
  EXPECT_TRUE(db.put("a", V("{x:1}")));
  EXPECT_FALSE(db.put("a", V("{x:2}")));
  ASSERT_TRUE(db.get("a"));
  EXPECT_EQ(render(*db.get("a")), "{\"x\":2}");
  db.erase("a");
  EXPECT_FALSE(db.get("a"));
  EXPECT_THROW(db.erase("a"), Error);
  EXPECT_EQ(db.stats().docs, 0u);
}

TEST(Database, FreshDatabaseIsOnePage) {
  Database db;
  EXPECT_EQ(db.main_file().size(), 1024u);
  EXPECT_EQ(db.wal_file().size(), 32u);
}

TEST(Database, ReplaceFreesThenAllocatesChain) {
  // Spec 14.3: replacing a 2005-byte document with itself reverses its chain.
  Database db;
  Value doc = V(big_doc(2005));
  db.put("a", doc);
  EXPECT_EQ(db.stats().pages, 4u);
  db.put("a", doc);
  Stats s = db.stats();
  EXPECT_EQ(s.pages, 4u);
  EXPECT_EQ(s.free_pages, 0u);
  EXPECT_EQ(*db.get("a"), doc);
  check_integrity(db);
}

TEST(Database, LargestDocumentAndLimit) {
  Database db;
  EXPECT_NO_THROW(db.put("a", V(big_doc(65536))));
  EXPECT_THROW(db.put("b", V(big_doc(65537))), Error);
  EXPECT_EQ(db.stats().docs, 1u);
  EXPECT_EQ(db.stats().pages, 1u + 1u + 65);  // overflow chain of 65 pages + root leaf
  check_integrity(db);
}

TEST(Database, ExplicitTransactionRollbackRestoresEverything) {
  Database db;
  db.put("a", V("1"));
  auto main_before = db.main_file();
  auto wal_before = db.wal_file();
  Stats before = db.stats();
  db.begin();
  for (int i = 0; i < 200; ++i) db.put("k" + std::to_string(i), V(big_doc(300)));
  db.erase("a");
  EXPECT_GT(db.stats().pages, before.pages);
  db.rollback();
  Stats after = db.stats();
  EXPECT_EQ(after.pages, before.pages);
  EXPECT_EQ(after.docs, before.docs);
  EXPECT_EQ(after.commits, before.commits);
  EXPECT_EQ(db.wal_file(), wal_before);
  EXPECT_EQ(db.main_file(), main_before);
  EXPECT_TRUE(db.get("a"));
  EXPECT_THROW(db.commit(), Error);
}

TEST(Database, FailedCommandInsideTransactionKeepsItOpen) {
  Database db;
  db.begin();
  EXPECT_THROW(db.erase("nope"), Error);
  EXPECT_TRUE(db.in_transaction());
  EXPECT_THROW(db.begin(), Error);
  EXPECT_THROW(db.checkpoint(), Error);
  db.put("a", V("1"));
  CommitInfo info = db.commit();
  EXPECT_EQ(info.txn_id, 1u);
  EXPECT_EQ(info.frames, 2u);
}

TEST(Database, FailedWriteChangesNothing) {
  Database db;
  db.put("a", V("{s:\"x\"}"));
  db.create_index({"s"});
  auto wal = db.wal_file();
  // An index key longer than 128 bytes is rejected without a trace.
  EXPECT_THROW(db.put("b", V("{s:\"" + std::string(130, 'q') + "\"}")), Error);
  EXPECT_THROW(db.update("a", {"s"}, V("\"" + std::string(130, 'q') + "\"")), Error);
  EXPECT_THROW(db.update("a", {"s", "t"}, V("1")), Error);
  EXPECT_THROW(db.unset("a", {"zz"}), Error);
  EXPECT_EQ(db.wal_file(), wal);
  EXPECT_EQ(db.stats().commits, 2u);
}

TEST(Database, IndexKeyLengthBoundary) {
  Database db;
  db.create_index({"s"});
  // key "k": 3 + S + 1 = 128  =>  S = 124
  EXPECT_NO_THROW(db.put("k", V("{s:\"" + std::string(124, 'q') + "\"}")));
  EXPECT_THROW(db.put("k2", V("{s:\"" + std::string(125, 'q') + "\"}")), Error);
  EXPECT_NO_THROW(db.put("k3", V("{s:[1]}")));  // lists are not indexed
  check_integrity(db);
}

TEST(Database, IndexSlotsAreReused) {
  Database db;
  db.create_index({"a"});
  db.create_index({"b"});
  db.drop_index({"a"});
  db.create_index({"c"});
  auto list = db.indexes();
  ASSERT_EQ(list.size(), 2u);
  EXPECT_EQ(list[0].path, "c");
  EXPECT_EQ(list[0].slot, 0u);
  EXPECT_EQ(list[1].path, "b");
  EXPECT_THROW(db.create_index({"b"}), Error);
  EXPECT_THROW(db.drop_index({"zz"}), Error);
}

TEST(Database, SixteenIndexesMax) {
  Database db;
  for (int i = 0; i < 16; ++i) db.create_index({"f" + std::to_string(i)});
  try {
    db.create_index({"extra"});
    FAIL();
  } catch (const Error& e) {
    EXPECT_EQ(e.kind(), ErrorKind::IndexLimit);
  }
}

TEST(Database, FindGivesTheSameAnswerWithAndWithoutAnIndex) {
  Database db;
  run_script(db,
             "put \"u1\" {age:36,name:\"ada\"}\n"
             "put \"u2\" {age:29,name:\"bob\"}\n"
             "put \"u3\" {age:\"36\"}\n"
             "put \"u4\" {name:\"cy\"}\n");
  const std::string queries =
      "find age >= 30\nfind age == 36\nfind age < 100\nfind age > 29\nfind age <= 29\n"
      "find age >= \"3\"\nfind age < \"4\"\nfind age > 29 limit 1\n";
  std::string scanned = run_script(db, queries);
  db.create_index({"age"});
  std::string indexed = run_script(db, queries);
  EXPECT_EQ(scanned.find("plan index"), std::string::npos);
  EXPECT_NE(indexed.find("plan index age"), std::string::npos);
  for (std::string::size_type p; (p = indexed.find("plan index age")) != std::string::npos;)
    indexed.replace(p, 14, "plan scan");
  EXPECT_EQ(indexed, scanned);
  EXPECT_NE(run_script(db, "find age != 29\n").find("plan scan"), std::string::npos);
}

TEST(Database, PlanTieBreaks) {
  Database db;
  db.create_index({"b"});
  db.create_index({"a"});
  db.put("k", V("{a:1,b:1}"));
  auto plan = [&](const char* line) {
    return run_line(db, line).status;
  };
  EXPECT_EQ(plan("find b == 1 and a == 1"), "ok find 1 plan index a");
  EXPECT_EQ(plan("find b < 5 and a == 1"), "ok find 1 plan index a");
  EXPECT_EQ(plan("find b == 1 and a < 5"), "ok find 1 plan index b");
  EXPECT_EQ(plan("find b < 5 and a < 5"), "ok find 1 plan index a");
  EXPECT_EQ(plan("find b == 1 or a == 1"), "ok find 1 plan scan");
  EXPECT_EQ(plan("find not(a == 2) and exists a"), "ok find 1 plan scan");
  EXPECT_EQ(plan("find a == [1]"), "ok find 0 plan scan");
}

TEST(Database, ScanBoundsAndLimits) {
  Database db;
  for (char c = 'a'; c <= 'j'; ++c) db.put(std::string(1, c), Value::integer(c));
  auto keys = [&](const std::string& opts) {
    return run_line(db, "scan keys " + opts);
  };
  EXPECT_EQ(keys("from \"c\" to \"f\"").status, "ok scan 3");
  EXPECT_EQ(keys("from \"c\" to \"f\" reverse").payload,
            (std::vector<std::string>{"\"e\"", "\"d\"", "\"c\""}));
  EXPECT_EQ(keys("reverse limit 2").payload, (std::vector<std::string>{"\"j\"", "\"i\""}));
  EXPECT_EQ(keys("from \"f\" to \"c\"").status, "ok scan 0");
  EXPECT_EQ(keys("from \"\"").status, "ok scan 10");
  EXPECT_EQ(keys("limit 0").status, "ok scan 0");
  EXPECT_EQ(keys("to \"a\"").status, "ok scan 0");
  EXPECT_EQ(keys("to \"b\"").status, "ok scan 1");
}

TEST(Database, AutomaticCheckpointAtWalLimit) {
  Database db;
  // Each put commits two page images: 32 + n * 2120 first reaches 262144 at n = 124.
  for (int i = 1; i <= 123; ++i) db.put("k", Value::integer(i));
  EXPECT_EQ(db.wal_file().size(), 32u + 123 * 2120);
  EXPECT_EQ(db.main_file().size(), 1024u);
  db.put("k", Value::integer(124));
  EXPECT_EQ(db.wal_file().size(), 32u);
  EXPECT_EQ(db.main_file().size(), 2048u);
  EXPECT_EQ(*db.get("k"), Value::integer(124));
}

TEST(Database, CheckpointCopiesLogIntoMainFile) {
  Database db;
  db.put("a", Value::integer(1));
  EXPECT_EQ(db.main_file().size(), 1024u);
  EXPECT_EQ(db.checkpoint(), 2u);
  EXPECT_EQ(db.main_file().size(), 2048u);
  EXPECT_EQ(db.wal_file().size(), 32u);
  EXPECT_EQ(db.checkpoint(), 0u);
  Database reopened(DatabaseImage{db.main_file(), db.wal_file()});
  EXPECT_EQ(*reopened.get("a"), Value::integer(1));
}

TEST(Database, MainFileWithoutLogReplaysOnFreshDatabase) {
  Database source;
  source.put("a", Value::integer(1));
  Database db(DatabaseImage{{}, source.wal_file()});
  EXPECT_EQ(*db.get("a"), Value::integer(1));
  EXPECT_EQ(db.main_file().size(), 1024u);
}

// A random workload checked against a std::map model, with periodic integrity
// checks, rollbacks and reopening from the produced files.
TEST(Database, RandomWorkloadAgainstModel) {
  for (unsigned seed = 1; seed <= 4; ++seed) {
    std::mt19937 rng(seed);
    Database db;
    std::map<std::string, Value> model, snapshot;
    bool in_txn = false;

    auto random_key = [&] {
      std::string k = "key" + std::to_string(rng() % 300);
      if (seed % 2 == 0) k += std::string(rng() % 100, 'p');
      return k;
    };
    auto random_doc = [&] {
      std::string age = std::to_string(int(rng() % 50) - 10);
      std::string text;
      switch (rng() % 8) {
        case 0: text = "{age:" + age + ",pad:\"" + std::string(rng() % 3000, 'v') + "\"}"; break;
        case 1: text = "{age:\"s" + age + "\",n:{m:" + age + "}}"; break;
        case 2: text = "{age:[1,2],n:null}"; break;
        case 3: text = age; break;
        case 4: text = "{n:{m:true}}"; break;
        default: text = "{age:" + age + ",n:{m:" + std::to_string(rng() % 5) + "}}"; break;
      }
      return V(text);
    };

    db.create_index({"age"});
    db.create_index({"n", "m"});

    for (int step = 0; step < 1500; ++step) {
      int op = static_cast<int>(rng() % 100);
      std::string k = random_key();
      if (op < 45) {
        Value d = random_doc();
        db.put(k, d);
        model[k] = d;
      } else if (op < 60) {
        if (model.count(k)) {
          db.erase(k);
          model.erase(k);
        } else {
          EXPECT_THROW(db.erase(k), Error);
        }
      } else if (op < 70) {
        if (model.count(k)) {
          Value nv = Value::integer(int(rng() % 40));
          try {
            db.update(k, {"age"}, nv);
            set_path(model[k], {"age"}, nv);
          } catch (const Error& e) {
            EXPECT_EQ(e.kind(), ErrorKind::NotObject);
            EXPECT_NE(model[k].kind(), Value::Kind::Object);
          }
        }
      } else if (op < 78) {
        if (model.count(k)) {
          try {
            db.unset(k, {"n", "m"});
            unset_path(model[k], {"n", "m"});
          } catch (const Error& e) {
            Value copy = model[k];
            EXPECT_THROW(unset_path(copy, {"n", "m"}), Error);
          }
        }
      } else if (op < 82) {
        if (!in_txn) {
          db.begin();
          in_txn = true;
          snapshot = model;
        }
      } else if (op < 86) {
        if (in_txn) {
          if (rng() % 2) {
            db.commit();
          } else {
            db.rollback();
            model = snapshot;
          }
          in_txn = false;
        }
      } else if (op < 88) {
        if (!in_txn) db.checkpoint();
      } else if (op < 94) {
        auto got = db.get(k);
        EXPECT_EQ(got.has_value(), model.count(k) == 1);
        if (got) EXPECT_EQ(*got, model[k]);
      } else {
        // find / scan agree with the model
        std::int64_t bound = int(rng() % 40);
        std::string line = "find age >= " + std::to_string(bound);
        Command c = parse_command(line);
        FindResult r = db.find(*c.predicate, std::nullopt);
        std::vector<std::string> got, want;
        for (auto& e : r.entries) got.push_back(e.key);
        for (auto& [mk, mv] : model)
          if (evaluate(*c.predicate, mv)) want.push_back(mk);
        EXPECT_EQ(got, want) << line;
      }
      if (step % 250 == 249 && !in_txn) {
        auto docs = check_integrity(db);
        EXPECT_EQ(docs, model);
        Database reopened(DatabaseImage{db.main_file(), db.wal_file()});
        EXPECT_EQ(reopened.main_file(), db.main_file());
        EXPECT_EQ(reopened.wal_file(), db.wal_file());
        EXPECT_EQ(reopened.stats().docs, model.size());
      }
    }
    if (in_txn) {
      db.rollback();
      model = snapshot;
    }
    EXPECT_EQ(check_integrity(db), model);
    // dropping an index frees all its pages
    db.drop_index({"age"});
    db.drop_index({"n", "m"});
    EXPECT_EQ(check_integrity(db), model);
  }
}
