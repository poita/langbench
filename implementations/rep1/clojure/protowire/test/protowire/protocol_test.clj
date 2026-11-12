(ns protowire.protocol-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [protowire.core :as pw]))

(deftest spec-example-1
  (is (= (str/join "\n" ["08011201781a02010222020809"
                         "{a: 1, b: \"x\", c: [1, 2], d: {v: -5}}"
                         "2200"
                         "{}"
                         "error"
                         ""])
         (pw/run-requests
          (str/join "\n" ["message Inner { sint32 v = 1; }"
                          "message Outer {"
                          "  int32 a = 1;"
                          "  string b = 2;"
                          "  repeated int32 c = 3;"
                          "  Inner d = 4;"
                          "}"
                          "--"
                          "encode Outer {a: 1, b: \"x\", c: [1, 2], d: {v: -5}}"
                          "decode Outer 08011201781a02010222020809"
                          "encode Outer {d: {}, c: [], a: 0}"
                          "decode Outer 3800"
                          "decode Outer 08ff"])))))

(deftest spec-example-2
  (is (= (str/join "\n" ["{u: 18446744073709551615, s: -128, f: 4294967295, y: x\"000f\", bs: [true, false, true]}"
                         "{k: true}"
                         "error"
                         "08ffffffffffffffffff0110ff012202cafe3001"
                         "error"
                         ""])
         (pw/run-requests
          (str/join "\n" ["message M { uint64 u = 1; sint64 s = 2; fixed32 f = 3; bytes y = 4; repeated bool bs = 5; bool k = 6; }"
                          "--"
                          "decode M 08ffffffffffffffffff0110ff011dffffffff2202000f2a03010001"
                          "decode M 3002"
                          "decode M 3d000000"
                          "encode M {k: true, y: x\"cafe\", s: -128, u: 18446744073709551615}"
                          "encode M {u: -1}\n"])))))

(deftest request-line-shapes
  (let [run #(pw/run-requests (str "message A { int32 x = 1; }\n--\n" %))]
    (testing "empty payload and empty encoding"
      (is (= "{}\n\n" (run "decode A\nencode A {}"))))
    (testing "malformed request lines"
      (is (= "error\nerror\nerror\nerror\nerror\nerror\nerror\n"
             (run (str/join "\n" ["decode A "
                                  "decode A 080"
                                  "decode A 08AB"
                                  "decode A 0801 00"
                                  "encode A"
                                  "encode A "
                                  "decode Nope 00"])))))
    (testing "final line without a trailing newline"
      (is (= "{x: 1}\n" (run "decode A 0801"))))
    (testing "later `--` lines are requests, not separators"
      (is (= "error\n" (run "--"))))
    (testing "a bad schema answers every request with error"
      (is (= "error\n" (pw/run-requests "message A { nope x = 1; }\n--\ndecode A 00\n"))))))
