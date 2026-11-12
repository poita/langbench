(ns kvstore.core-test
  "Tests of the public library API."
  (:require [clojure.test :refer [deftest is testing]]
            [kvstore.core :as kv]))

(defn kind [f]
  (try (f) :no-error
       (catch clojure.lang.ExceptionInfo e (:kind (ex-data e)))))

(deftest documents
  (let [db (kv/open)]
    (is (= :created (kv/put! db "u1" {"name" "ada" "age" 36})))
    (is (= :replaced (kv/put! db "u1" {"name" "ada" "age" 37})))
    (is (= {"name" "ada" "age" 37} (kv/get db "u1")))
    (is (= :not-found (kind #(kv/get db "nope"))))
    (is (= :bad-key (kind #(kv/put! db "" 1))))
    (is (= :bad-key (kind #(kv/put! db (apply str (repeat 129 "k")) 1))))
    (is (= :depth (kind #(kv/put! db "d" (reduce (fn [acc _] [acc]) [] (range 32))))))
    (is (= :doc-too-large (kind #(kv/put! db "big" (apply str (repeat 65536 "x"))))))
    (kv/update! db "u1" "addr.city" "oslo")
    (is (= {"name" "ada" "age" 37 "addr" {"city" "oslo"}} (kv/get db "u1")))
    (kv/unset! db "u1" "addr.city")
    (is (= {} (get (kv/get db "u1") "addr")))
    (is (= :no-field (kind #(kv/unset! db "u1" "addr.zip"))))
    (is (= :not-object (kind #(kv/update! db "u1" "name.first" "a"))))
    (kv/delete! db "u1")
    (is (= :not-found (kind #(kv/delete! db "u1"))))
    (is (= 0 (:docs (kv/stat db))))))

(deftest scanning
  (let [db (kv/open)]
    (doseq [k ["a" "b" "c" "d"]] (kv/put! db k k))
    (is (= [["a" "a"] ["b" "b"] ["c" "c"] ["d" "d"]] (kv/scan db)))
    (is (= ["b" "c"] (kv/scan db {:from "b" :to "d" :keys? true})))
    (is (= ["d" "c"] (kv/scan db {:reverse? true :limit 2 :keys? true})))
    (is (= [] (kv/scan db {:from "d" :to "b"})))))

(deftest indexes-and-find
  (let [db (kv/open)]
    (kv/put! db "u1" {"name" "ada" "age" 36})
    (kv/put! db "u2" {"name" "bob" "age" 29})
    (kv/put! db "u3" {"name" "cy" "age" 36})
    (is (= {:plan "scan" :rows [["u1" {"name" "ada" "age" 36}] ["u3" {"name" "cy" "age" 36}]]}
           (kv/find db "age == 36")))
    (is (= 3 (kv/create-index! db "age")))
    (is (= [{:slot 0 :path "age" :root 3 :entries 3}] (kv/indexes db)))
    (is (= "index age" (:plan (kv/find db "age == 36"))))
    (is (= ["u1"] (map first (:rows (kv/find db "age == 36" {:limit 1})))))
    (is (= ["u1" "u3"] (map first (:rows (kv/find db "age > 30")))))
    (is (= :index-exists (kind #(kv/create-index! db "age"))))
    (kv/put! db "u2" {"age" 40})
    (is (= ["u2"] (map first (:rows (kv/find db "age > 36")))))
    (is (= 1 (kv/drop-index! db "age")))
    (is (= :index-missing (kind #(kv/drop-index! db "age"))))
    (is (= :index-key-too-long
           (do (kv/create-index! db "name")
               (kind #(kv/put! db "u9" {"name" (apply str (repeat 125 "x"))})))))))

(deftest transactions
  (let [db (kv/open)]
    (kv/begin! db)
    (is (= :txn-active (kind #(kv/begin! db))))
    (is (= :txn-active (kind #(kv/checkpoint! db))))
    (kv/put! db "a" 1)
    (kv/rollback! db)
    (is (= :not-found (kind #(kv/get db "a"))))
    (is (= :no-txn (kind #(kv/commit! db))))
    (kv/begin! db)
    (kv/put! db "a" 1)
    (is (= {:txn-id 1 :frames 2} (kv/commit! db)))
    (is (= 2 (kv/checkpoint! db)))
    (is (= 32 (:wal (kv/stat db))))))

(deftest files-round-trip
  (let [db (kv/open)]
    (doseq [i (range 200)] (kv/put! db (str "key" i) {"i" i "pad" (apply str (repeat 50 "x"))}))
    (let [{:keys [main wal]} (kv/files db)
          again (kv/open {:main main :wal wal})]
      (is (= (kv/scan db) (kv/scan again))))
    (kv/checkpoint! db)
    (let [again (kv/open (kv/files db))]
      (is (= (kv/scan db) (kv/scan again)))
      (is (= 32 (alength ^bytes (:wal (kv/files again))))))))

(deftest execute-command-language
  (let [db (kv/open)]
    (is (= {:status "ok put created" :lines []} (kv/execute! db "put \"a\" [1,2]")))
    (is (= {:status "ok get value" :lines ["[1,2]"]} (kv/execute! db "get \"a\"")))
    (is (= {:status "error syntax" :lines []} (kv/execute! db "put")))
    (is (= {:status "ok begin" :lines []} (kv/execute! db "begin")))
    (kv/execute! db "put \"b\" 1")
    (kv/close! db)
    (is (= ["a"] (kv/scan db {:keys? true})) "close! rolls back the open transaction")))
