#include <gtest/gtest.h>

#include "typeinfer/session.hpp"

using namespace typeinfer;

TEST(Session, EmptyProgram) {
    Session s;
    EXPECT_TRUE(s.check("").empty());
    EXPECT_TRUE(s.check("  \n\t").empty());
}

TEST(Session, ResultFields) {
    Session s;
    auto rs = s.check("let id = fun x -> x;; id;; nope;;");
    ASSERT_EQ(rs.size(), 3u);
    EXPECT_TRUE(rs[0].ok());
    EXPECT_EQ(rs[0].name, "id");
    EXPECT_EQ(rs[0].type, "'a -> 'a");
    EXPECT_FALSE(rs[1].name.has_value());
    EXPECT_FALSE(rs[2].ok());
    EXPECT_EQ(rs[2].error, ErrorKind::Unbound);
    EXPECT_EQ(rs[2].to_string(), "error: unbound");
}

TEST(Session, EnvironmentPersistsAcrossCalls) {
    Session s;
    s.check("let id = fun x -> x;;");
    auto rs = s.check("(id 1, id true);;");
    ASSERT_EQ(rs.size(), 1u);
    EXPECT_EQ(rs[0].to_string(), "- : int * bool");
}

TEST(Session, SinkReceivesResultsInOrder) {
    Session s;
    std::vector<std::string> lines;
    s.check("1;; true;;", [&](DeclResult&& r) { lines.push_back(r.to_string()); });
    EXPECT_EQ(lines, (std::vector<std::string>{"- : int", "- : bool"}));
}

TEST(Session, ParseErrorThrowsAfterEarlierDeclarationsTookEffect) {
    Session s;
    EXPECT_THROW(s.check("let x = 1;; let = ;;"), ParseError);
    auto rs = s.check("x;;");
    ASSERT_EQ(rs.size(), 1u);
    EXPECT_EQ(rs[0].to_string(), "- : int");
}

TEST(Session, ErrorKindSpelling) {
    EXPECT_STREQ(to_string(ErrorKind::Unify), "unify");
    EXPECT_STREQ(to_string(ErrorKind::Occurs), "occurs");
    EXPECT_STREQ(to_string(ErrorKind::Unbound), "unbound");
}

TEST(Session, ManyTopLevelBindings) {
    std::string src;
    for (int i = 0; i < 5000; ++i) src += "let v" + std::to_string(i) + " = fun x -> x;;\n";
    src += "v4999 1;;";
    Session s;
    auto rs = s.check(src);
    ASSERT_EQ(rs.size(), 5001u);
    EXPECT_EQ(rs.back().to_string(), "- : int");
}
