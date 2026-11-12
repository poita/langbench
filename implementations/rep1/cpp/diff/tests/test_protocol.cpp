#include <gtest/gtest.h>

#include "mdiff/protocol.hpp"
#include "mdiff/patch.hpp"

using namespace mdiff;

TEST(Protocol, DiffMyersExampleCost) {
  std::string in = "diff\n7\na\nb\nc\na\nb\nb\na\n6\nc\nb\na\nb\na\nc\n";
  std::string out = process_request(in);
  EXPECT_EQ(out.substr(0, 2), "9\n");
}

TEST(Protocol, DiffBothEmpty) { EXPECT_EQ(process_request("diff\n0\n0\n"), "0\n"); }

TEST(Protocol, DiffIdentical) {
  EXPECT_EQ(process_request("diff\n2\nx\n\n2\nx\n\n"), "2\n x\n \n");
}

TEST(Protocol, DiffContentLooksLikeCount) {
  // A has the single line "1" ; B has none.
  EXPECT_EQ(process_request("diff\n1\n1\n0\n"), "1\n-1\n");
}

TEST(Protocol, PatchSpecExample) {
  std::string in = "patch\n5\na\nb\nc\nd\ne\n8\n a\n-b\n+B\n c\n+c2\n-d\n e\n+f\n";
  EXPECT_EQ(process_request(in), "6\na\nB\nc\nc2\ne\nf\n");
}

TEST(Protocol, PatchEmptyResult) { EXPECT_EQ(process_request("patch\n1\nq\n1\n-q\n"), "0\n"); }

TEST(Protocol, PatchKeepsTrailingSpaces) {
  EXPECT_EQ(process_request("patch\n0\n2\n+a \n+ \n"), "2\na \n \n");
}

TEST(Protocol, LenientInput) {
  EXPECT_EQ(process_request("diff\n1 \na\n1\t\na"), "1\n a\n");
  EXPECT_EQ(process_request("diff\r\n1\r\na\n1\r\na"), "1\n a\n");
  EXPECT_EQ(process_request("diff\n0\n1\nz\n\n\n"), "1\n+z\n");
}

TEST(Protocol, Errors) {
  EXPECT_THROW(process_request(""), ProtocolError);
  EXPECT_THROW(process_request("bogus\n0\n"), ProtocolError);
  EXPECT_THROW(process_request("diff\n2\na\n"), ProtocolError);
  EXPECT_THROW(process_request("diff\nx\n"), ProtocolError);
  EXPECT_THROW(process_request("patch\n1\na\n1\n b\n"), ScriptError);
}
