import pytest

from protowire import parse_schema

SCHEMA_TEXT = """
message Inner { sint32 v = 1; }
message Outer {
  int32 a = 1;
  string b = 2;
  repeated int32 c = 3;
  Inner d = 4;
}
message Kinds {
  int32 i32 = 1; int64 i64 = 2; uint32 u32 = 3; uint64 u64 = 4;
  sint32 s32 = 5; sint64 s64 = 6; bool b = 7;
  fixed32 f32 = 8; sfixed32 sf32 = 9; fixed64 f64 = 10; sfixed64 sf64 = 11;
  string s = 12; bytes y = 13;
  repeated sint64 rs = 14; repeated fixed32 rf = 15; repeated bool rb = 16;
  repeated string rstr = 17; repeated Inner rin = 18;
}
message Node { repeated int32 r = 1; Node next = 2; string s = 3; }
"""


@pytest.fixture(scope="session")
def schema():
    return parse_schema(SCHEMA_TEXT)
