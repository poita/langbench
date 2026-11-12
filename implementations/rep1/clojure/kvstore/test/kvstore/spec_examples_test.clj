(ns kvstore.spec-examples-test
  "The worked examples of spec section 21, end to end."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [kvstore.bytes :as b]
            [kvstore.test-util :as tu]))

(defn- stat-block [pages free freehead docs root height commits indexes wal]
  (str "  pages " pages "\n  free " free "\n  freehead " freehead "\n  docs " docs
       "\n  root " root "\n  height " height "\n  commits " commits
       "\n  indexes " indexes "\n  wal " wal "\n"))

(deftest one-document-then-a-checkpoint
  (let [{:keys [results main wal]} (tu/script ["put \"a\" 1" "checkpoint" "stat"])]
    (is (= (str "[1] ok put created\n[2] ok checkpoint pages 2\n[3] ok stat\n"
                (stat-block 2 0 0 1 2 1 1 0 32))
           results))
    (is (= 2048 (alength ^bytes main)))
    (testing "page 1 is the header of section 7.2"
      (is (str/starts-with? (tu/hex-page main 1)
                            (str "5445535345524131" "0001" "0400" "00000002" "00000000" "00000000"
                                 "00000002" "00000001" "0000000000000001" "00000000"))))
    (testing "page 2 is the leaf of section 11.3"
      (let [p (tu/hex-page main 2)]
        (is (str/starts-with? p "01000001" ))
        (is (str/ends-with? p "000000010000000900090000000061030000000000000001"))))
    (is (= "5445535357414c31000104000000000000000000000000000000000051e72153" (b/hex wal)))))

(deftest free-list-reuse
  (is (= (str "[1] ok put created\n[2] ok put created\n[3] ok delete removed\n[4] ok delete removed\n"
              "[5] ok stat\n" (stat-block 2 1 2 0 0 0 4 0 8512)
              "[6] ok put created\n[7] ok stat\n" (stat-block 2 0 0 1 2 1 5 0 10632))
         (tu/results ["put \"k1\" \"x\"" "put \"k2\" \"y\"" "delete \"k1\"" "delete \"k2\""
                      "stat" "put \"k3\" \"z\"" "stat"]))))

(deftest overflow-chain
  (let [doc (str "[" (str/join "," (range 1 26)) "]")]
    (is (= (str "[1] ok put created\n[2] ok stat\n" (stat-block 3 0 0 1 3 1 1 0 3200)
                "[3] ok get value\n  " doc "\n[4] ok delete removed\n[5] ok stat\n"
                (stat-block 3 2 3 0 0 0 2 0 6368))
           (tu/results [(str "put \"big\" " doc) "stat" "get \"big\"" "delete \"big\"" "stat"])))))

(deftest rollback-and-commit
  (is (= (str "[1] ok begin\n[2] ok put created\n[3] ok put created\n[4] ok stat\n"
              (stat-block 2 0 0 2 2 1 0 0 32)
              "[5] ok rollback\n[6] ok stat\n" (stat-block 1 0 0 0 0 0 0 0 32)
              "[7] ok begin\n[8] ok put created\n[9] ok commit 1 frames 2\n[10] ok stat\n"
              (stat-block 2 0 0 1 2 1 1 0 2152))
         (tu/results ["begin" "put \"a\" 1" "put \"b\" 2" "stat" "rollback" "stat"
                      "begin" "put \"a\" 1" "commit" "stat"]))))

(deftest errors
  (is (= ["error not-found" "error not-found" "error unknown-command" "error syntax"
          "error syntax" "error int-range" "error dup-field" "error bad-utf8" "error bad-key"
          "error no-txn" "error no-txn" "ok begin" "error txn-active" "error txn-active"]
         (subvec (tu/statuses ["put \"a\" 1" "put \"a\" 2" "get \"zz\"" "delete \"zz\"" "frobnicate"
                               "put \"a\"" "put \"a\" 007" "put \"a\" 9223372036854775808"
                               "put \"a\" {x:1,x:2}" "put \"\\ud800\" 1" "put \"\" 1"
                               "commit" "rollback" "begin" "begin" "checkpoint"])
                 2))))

(deftest secondary-index-and-find
  (is (= (str "[1] ok put created\n[2] ok put created\n[3] ok put created\n"
              "[4] ok create index age entries 3\n[5] ok indexes 1\n  0 age root 3 entries 3\n"
              "[6] ok find 2 plan index age\n  \"u1\" = {\"age\":36,\"name\":\"ada\"}\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n"
              "[7] ok find 2 plan index age\n  \"u1\" = {\"age\":36,\"name\":\"ada\"}\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n"
              "[8] ok find 1 plan index age\n  \"u3\" = {\"age\":36,\"name\":\"cy\"}\n"
              "[9] ok find 1 plan scan\n  \"u2\" = {\"age\":29,\"name\":\"bob\"}\n"
              "[10] ok stat\n" (stat-block 3 0 0 3 2 1 4 1 8512))
         (tu/results ["put \"u1\" {name:\"ada\",age:36}" "put \"u2\" {name:\"bob\",age:29}"
                      "put \"u3\" {name:\"cy\",age:36}" "create index age" "indexes"
                      "find age == 36" "find age > 30" "find age == 36 and name == \"cy\""
                      "find not(age == 36)" "stat"]))))

(deftest scan-ranges
  (is (= (str "[5] ok scan 4\n  \"a\" = 1\n  \"b\" = 2\n  \"c\" = 3\n  \"d\" = 4\n"
              "[6] ok scan 3\n  \"b\" = 2\n  \"c\" = 3\n  \"d\" = 4\n"
              "[7] ok scan 2\n  \"a\" = 1\n  \"b\" = 2\n"
              "[8] ok scan 2\n  \"b\" = 2\n  \"c\" = 3\n"
              "[9] ok scan 2\n  \"a\" = 1\n  \"b\" = 2\n"
              "[10] ok scan 2\n  \"d\" = 4\n  \"c\" = 3\n"
              "[11] ok scan 4\n  \"d\"\n  \"c\"\n  \"b\"\n  \"a\"\n"
              "[12] ok scan 0\n")
         (->> (tu/results ["put \"a\" 1" "put \"b\" 2" "put \"c\" 3" "put \"d\" 4" "scan" "scan from \"b\""
                           "scan to \"c\"" "scan from \"b\" to \"d\"" "scan limit 2"
                           "scan reverse limit 2" "scan keys reverse" "scan from \"d\" to \"b\""])
              str/split-lines
              (drop 4)
              (str/join "\n")
              (#(str % "\n"))))))

(deftest update-and-unset
  (is (= ["ok put created" "ok update updated" "ok update updated" "ok get value" "ok unset updated"
          "ok get value" "error no-field" "error not-object" "error not-found"]
         (tu/statuses ["put \"u1\" {name:\"ada\"}" "update \"u1\" age 36" "update \"u1\" addr.city \"oslo\""
                       "get \"u1\"" "unset \"u1\" addr.city" "get \"u1\"" "unset \"u1\" addr.zip"
                       "unset \"u1\" name.first" "update \"u2\" age 1"])))
  (is (str/includes? (tu/results ["put \"u1\" {name:\"ada\"}" "update \"u1\" age 36"
                                  "update \"u1\" addr.city \"oslo\"" "get \"u1\""])
                     "{\"addr\":{\"city\":\"oslo\"},\"age\":36,\"name\":\"ada\"}")))

(deftest checkpoint-and-drop-index
  (let [{:keys [results main wal]}
        (tu/script ["put \"u1\" {age:1}" "create index age" "stat" "checkpoint" "stat"
                    "drop index age" "stat" "drop index age"])]
    (is (str/includes? results "[4] ok checkpoint pages 3\n"))
    (is (str/includes? results "[6] ok drop index age pages 1\n"))
    (is (str/ends-with? results "[8] error index-missing\n"))
    (is (= 3072 (alength ^bytes main)))
    (is (= 2152 (alength ^bytes wal)))))

(def ^:private twenty "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]")

(deftest split-borrow-merge
  (let [puts (for [i (range 1 7)] (str "put \"k" i "\" " twenty))
        out (tu/results (concat puts ["stat" "scan keys" "delete \"k1\"" "delete \"k2\"" "delete \"k3\"" "stat"]))]
    (is (str/includes? out (str "[7] ok stat\n" (stat-block 4 0 0 6 4 2 6 0 14848))))
    (is (str/includes? out (str "[12] ok stat\n" (stat-block 4 2 4 3 2 1 9 0 25400))))))

(deftest thin-page-after-replace
  (let [puts (for [i (range 1 7)] (str "put \"k" i "\" " twenty))
        out (tu/results (concat puts ["put \"k1\" 1" "put \"k2\" 2" "stat" "delete \"k3\"" "stat"]))]
    (is (str/includes? out (str "[9] ok stat\n" (stat-block 4 0 0 6 4 2 8 0 19088))))
    (is (str/includes? out (str "[11] ok stat\n" (stat-block 4 0 0 5 4 2 9 0 23304))))))

(deftest empty-script
  (let [{:keys [results main wal]} (tu/script "")]
    (is (= "" results))
    (is (= 1024 (alength ^bytes main)))
    (is (= 32 (alength ^bytes wal)))))

(deftest line-splitting
  (is (= ["[1] ok begin" "[2] error syntax"] (str/split-lines (tu/results "begin\n\n"))))
  (is (= ["[1] ok begin" "[2] error syntax" "[3] error syntax"] (str/split-lines (tu/results "begin\n\n\n")))))
