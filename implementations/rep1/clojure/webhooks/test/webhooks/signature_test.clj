(ns webhooks.signature-test
  (:require [clojure.test :refer [deftest is testing]]
            [webhooks.bytes :as bytes]
            [webhooks.hex :as hex]
            [webhooks.signature :as sig]))

(def secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
(def id "msg_p5jXN8AQM9LWM0D4loKWxJek")
(def body (bytes/utf8 "{\"test\": 2432232314}"))
(def good "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
(def key0 (sig/parse-secret secret))

(deftest secrets
  (is (= "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0" (hex/encode key0)))
  (is (= (seq key0) (seq (sig/parse-secret "MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"))))
  (is (= 25 (alength ^bytes (sig/parse-secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr"))))
  (testing "only one prefix is stripped"
    (is (= 4 (alength ^bytes (sig/parse-secret "whsec_whsec_")))
        "the second prefix is Base64 data"))
  (is (nil? (sig/parse-secret "whsec_")))
  (is (nil? (sig/parse-secret "!!!!"))))

(deftest timestamps
  (is (= 0 (sig/parse-timestamp "0")))
  (is (= -15 (sig/parse-timestamp "-15")))
  (is (= 1000000000000000 (sig/parse-timestamp "1000000000000000")))
  (doseq [s ["" "-" "-0" "007" "+5" "1.0" "1e3" "1000000000000001" " 1"]]
    (is (nil? (sig/parse-timestamp s)) (pr-str s))))

(deftest signing
  (is (= good (sig/signature-header [key0] id "1614265330" body)))
  (let [k1 (sig/parse-secret "c2VjcmV0")
        h (sig/signature-header [key0 k1] id "1614265330" body)]
    (is (= [good] (take 1 (clojure.string/split h #" "))))
    (is (= 2 (count (clojure.string/split h #" "))))))

(defn- verify [header & {:as over}]
  (sig/verify [key0] (merge {:id id :timestamp "1614265330" :signature header
                             :body body :now 1614265400}
                            over)))

(deftest verification
  (is (= {:ok true :secret 0 :token 0} (verify good)))
  (is (= {:ok true :secret 0 :token 1} (verify (str "garbage " good))))
  (is (= {:ok true :secret 0 :token 2} (verify (str "x  " good))))
  (testing "reasons, in order"
    (is (= :missing-signature (:reason (verify "" :timestamp "bad"))))
    (is (= :missing-signature (:reason (verify "  "))))
    (is (= :invalid-timestamp (:reason (verify good :timestamp "01"))))
    (is (= :timestamp-too-old (:reason (verify good :now 1614265631))))
    (is (:ok (verify good :now 1614265630)))
    (is (= :timestamp-too-new (:reason (verify good :now (- 1614265330 301)))))
    (is (:ok (verify good :now (- 1614265330 300))))
    (is (= :no-match (:reason (verify good :body (bytes/utf8 "{}")))))
    (is (= :no-match (:reason (verify "v2,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="))))
    (is (= :no-match (:reason (verify "v1g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="))))))

(deftest rotation
  (let [k1 (sig/parse-secret "c2VjcmV0")
        h1 (sig/signature-header [k1] id "1614265330" body)]
    (is (= {:ok true :secret 1 :token 0}
           (sig/verify [k1 key0] {:id id :timestamp "1614265330" :signature good
                                  :body body :now 1614265330})))
    (testing "secret order wins over token order"
      (is (= {:ok true :secret 0 :token 1}
             (sig/verify [k1 key0] {:id id :timestamp "1614265330"
                                    :signature (str good " " h1)
                                    :body body :now 1614265330}))))))
