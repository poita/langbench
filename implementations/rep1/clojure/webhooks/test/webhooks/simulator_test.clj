(ns webhooks.simulator-test
  (:require [clojure.test :refer [deftest is testing]]
            [webhooks.bytes :as bytes]
            [webhooks.signature :as sig]
            [webhooks.simulator :as sim]))

(defn- ep [id script & {:keys [filter]}]
  {:id id :keys [(sig/parse-secret "c2VjcmV0")] :filter filter :script script})

(defn- ev [id ts & [type]]
  {:id id :timestamp ts :type (or type "t") :payload (bytes/utf8 "{}")})

(defn- attempt-times [result]
  (mapv :ts (:attempts result)))

(deftest retry-schedule
  (let [r (sim/simulate [(ep "a" [500])] [(ev "e" 100)])]
    (is (= [100 105 405 2205 9405 27405 63405 99405] (attempt-times r)))
    (is (= [1 2 3 4 5 6 7 8] (map :n (:attempts r))))
    (is (= {:event "e" :endpoint "a" :status :failed :attempts 8 :last-ts 99405}
           (select-keys (first (:deliveries r)) [:event :endpoint :status :attempts :last-ts])))))

(deftest outcomes
  (let [r (sim/simulate [(ep "a" [500 :timeout 204])] [(ev "e" 0)])]
    (is (= [:failure :timeout :success] (map :outcome (:attempts r))))
    (is (= [500 nil 204] (map :code (:attempts r))))
    (is (= :delivered (:status (first (:deliveries r)))))))

(deftest gone-disables-endpoint
  (let [r (sim/simulate [(ep "a" [500 410])] [(ev "e1" 0) (ev "e2" 1)])]
    ;; e1 fails at 0 (500); e2 gets 410 at 1, disabling a; e1's retry is dropped
    (is (= [:failure :gone] (map :outcome (:attempts r))))
    (is (= [[:disabled 1 0] [:failed 1 1]]
           (map (juxt :status :attempts :last-ts) (:deliveries r))))))

(deftest disabled-without-attempts
  (let [r (sim/simulate [(ep "a" [410])] [(ev "e1" 0) (ev "e2" 0)])
        [d1 d2] (:deliveries r)]
    (is (= :failed (:status d1)))
    (is (= [:disabled 0 nil] [(:status d2) (:attempts d2) (:last-ts d2)]))))

(deftest filters-and-ordering
  (let [r (sim/simulate [(ep "a" [200] :filter #{"x"}) (ep "b" [200])]
                        [(ev "late" 50 "y") (ev "early" 10 "x")])]
    (is (= [["late" "b"] ["early" "a"] ["early" "b"]]
           (map (juxt :event :endpoint) (:deliveries r))))
    (is (= ["early" "early" "late"] (map :event (:attempts r))))
    (is (= [1 2 3] (map :seq (:attempts r))))))

(deftest signs-each-delivery-once-with-all-secrets
  (let [e {:id "a" :keys [(sig/parse-secret "c2VjcmV0") (sig/parse-secret "b3RoZXI")]
           :filter nil :script [200]}
        r (sim/simulate [e] [(ev "e" 0)])]
    (is (= 2 (count (clojure.string/split (:header (first (:deliveries r))) #" "))))))
