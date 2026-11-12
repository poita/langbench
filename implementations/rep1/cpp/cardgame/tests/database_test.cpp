#include <gtest/gtest.h>

#include "spiremark/database.hpp"

using namespace spiremark;

namespace {
const char* kGood = R"(
(card AAA-001 (name "Bolt") (type rite) (cost 1) (tags fire) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card AAA-002 (name "Guard") (type unit) (cost 2) (body 1 3) (keywords (plating 1) vigil)
  (on arrive (draw 1 you))
  (act (cost (ember 1) (exhaust)) (targets (unit (enemy))) (damage 1 (t 1))))
(card AAA-003 (name "Shrine") (type relic) (cost 3)
  (aura (when (myturn) (modify 1 1 (units yours)))))
)";
}

TEST(Database, ParsesCardsAndAbilities) {
    Database db = Database::parse(kGood);
    EXPECT_EQ(db.size(), 3u);
    const Card* c = db.find("AAA-002");
    ASSERT_NE(c, nullptr);
    EXPECT_EQ(c->type, CardType::Unit);
    EXPECT_EQ(c->edge, 1);
    EXPECT_EQ(c->core, 3);
    EXPECT_EQ(c->plating_sum, 1);
    EXPECT_TRUE(c->has_printed_kw(Kw::Vigil));
    ASSERT_EQ(c->abilities.size(), 2u);
    EXPECT_EQ(c->abilities[0].kind, Ability::Kind::On);
    EXPECT_EQ(c->abilities[1].kind, Ability::Kind::Act);
    EXPECT_EQ(db.find("AAA-999"), nullptr);
}

TEST(Database, AbilityNumberingPutsResolveFirstThenOnActAura) {
    Database db = Database::parse(
        "(card AAA-001 (name \"X\") (type unit) (cost 0) (body 1 1)"
        " (aura (modify 1 0 self)) (act (cost (once)) (draw 1 you)) (on arrive (draw 1 you)))");
    const Card* c = db.find("AAA-001");
    ASSERT_EQ(c->abilities.size(), 3u);
    EXPECT_EQ(c->abilities[0].kind, Ability::Kind::On);
    EXPECT_EQ(c->abilities[1].kind, Ability::Kind::Act);
    EXPECT_EQ(c->abilities[2].kind, Ability::Kind::Aura);
}

TEST(Database, DescribeMatchesTheCardBlockFormat) {
    Database db = Database::parse(kGood);
    EXPECT_EQ(db.describe("AAA-001"),
              "CARD BEGIN AAA-001\nname Bolt\ntype rite\ncost 1\ntags fire\nkeywords swift\n"
              "ability 1 resolve (targets (any)) (damage 2 (t 1))\nCARD END\n");
    EXPECT_EQ(db.describe("AAA-003"),
              "CARD BEGIN AAA-003\nname Shrine\ntype relic\ncost 3\ntags -\nkeywords -\n"
              "ability 1 aura (when (myturn) (modify 1 1 (units yours)))\nCARD END\n");
    EXPECT_EQ(db.describe("ZZZ-000"), "CARD BEGIN ZZZ-000\nunknown\nCARD END\n");
    std::string unit = db.describe("AAA-002");
    EXPECT_NE(unit.find("body 1/3\n"), std::string::npos);
    EXPECT_NE(unit.find("keywords plating:1,vigil\n"), std::string::npos);
    EXPECT_NE(unit.find("ability 1 on arrive - (draw 1 you)\n"), std::string::npos);
}

TEST(Database, EmptyFileIsValid) {
    EXPECT_EQ(Database::parse("; nothing\n").size(), 0u);
}

TEST(Database, RejectsInvalidDatabases) {
    const char* bad[] = {
        "(card aaa-001 (name \"x\") (type unit) (cost 0) (body 1 1))",                  // id case
        "(card AAA-001 (type unit) (cost 0) (body 1 1))",                                // no name
        "(card AAA-001 (name \"x\") (type unit) (cost 0))",                              // unit w/o body
        "(card AAA-001 (name \"x\") (type rite) (cost 1))",                              // rite w/o resolve
        "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1) (keywords swift))",  // swift on unit
        "(card AAA-001 (name \"x\") (type relic) (cost 0) (keywords vanguard))",         // kw on relic
        "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1) (act (draw 1 you)))",// act w/o cost
        "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (draw 1 you) (targets (unit))))",
        "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (damage 2)))",         // arity
        "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (summon BBB-002 1 you)))",
        "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (negate self)))",
        "(card AAA-001 (name \"x\") (type rite) (cost 1) (resolve (if (myturn) (draw 1 you))))",
        "(card AAA-001 (name \"x\") (type unit) (cost 99999999999999999999) (body 1 1))",
        "(card AAA-001 (name \"x\") (type unit) (cost 0) (body 1 1))"
        "(card AAA-001 (name \"y\") (type unit) (cost 0) (body 1 1))",                    // duplicate
        "(card AAA-002 (name \"x\") (type rite) (cost 1) (resolve (nothing)))"
        "(card AAA-001 (name \"y\") (type unit) (cost 0) (body 1 1) (on arrive (summon AAA-002 1 you)))",
    };
    for (const char* text : bad) EXPECT_THROW(Database::parse(text), DatabaseError) << text;
}

TEST(Database, MissingFileIsAnError) {
    EXPECT_THROW(Database::load_file("/nonexistent/cards.spire"), DatabaseError);
}
