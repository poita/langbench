(ns protowire.test-util
  "Shared helpers for the protowire tests."
  (:require [clojure.test :as t]
            [protowire.core :as pw]))

(def example-schema
  (pw/parse-schema
   "message Inner { sint32 v = 1; }
    message Outer {
      int32 a = 1;
      string b = 2;
      repeated int32 c = 3;
      Inner d = 4;
    }"))

(def all-types-schema
  (pw/parse-schema
   "message Node { int32 i32 = 1; int64 i64 = 2; uint32 u32 = 3; uint64 u64 = 4;
                   sint32 s32 = 5; sint64 s64 = 6; bool b = 7;
                   fixed32 f32 = 8; sfixed32 sf32 = 9; fixed64 f64 = 10; sfixed64 sf64 = 11;
                   string s = 12; bytes y = 13; Node child = 14;
                   repeated int32 ri32 = 15; repeated uint64 ru64 = 16; repeated sint64 rs64 = 17;
                   repeated bool rb = 18; repeated fixed32 rf32 = 19; repeated sfixed64 rsf64 = 20;
                   repeated string rs = 21; repeated bytes ry = 22; repeated Node rn = 23; }"))

(defn bytes-of
  "Byte array from a seq of ints (0..255)."
  [& xs]
  (byte-array (map unchecked-byte xs)))

(defmacro is-error
  "Asserts that `form` throws a protowire error."
  [form]
  `(t/is (~'thrown-with-msg? clojure.lang.ExceptionInfo #"" ~form)))

(defn error? [f]
  (try (f) false (catch clojure.lang.ExceptionInfo e (pw/error? e))))
