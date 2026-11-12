(ns webhooks.commands-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [webhooks.cli :as cli]
            [webhooks.commands :as commands]
            [webhooks.bytes :as bytes]))

(defn run
  "Runs the newline-separated `input` through the protocol; returns the output
  lines."
  [input]
  (vec (mapcat str/split-lines
               (commands/process (cli/read-lines (bytes/utf8 input))))))

(def P "7b2274657374223a20323433323233323331347d")
(def H "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d")
(def S "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw")
(def I "msg_p5jXN8AQM9LWM0D4loKWxJek")

(deftest spec-examples
  (is (= ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
          "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad"
          "Zm9v" "-_8" "666f6f" "-"
          "31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0"
          "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
          "ok 0 0" "fail timestamp-too-old" "fail no-match" "fail missing-signature"
          "error" "error" "error"]
         (run (str "sha256 -\nsha256 616263\nhmac - -\nb64enc 666f6f\nb64urlenc fbff\n"
                   "b64dec 5a6d3976\nb64dec -\nsecret " S "\n"
                   "sign " S " " I " 1614265330 " P "\n"
                   "verify " S " " I " 1614265330 1614265400 " H " " P "\n"
                   "verify " S " " I " 1614265330 1614265631 " H " " P "\n"
                   "verify " S " " I " 1614265330 1614265400 " H " 7b7d\n"
                   "verify " S " " I " 1614265330 1614265400 - " P "\n"
                   "sha256 ABCD\nsha256 abc\nfrobnicate 1\n")))))

(deftest blank-lines-and-spacing
  (is (= ["-" "error" "error" "error"]
         (run "\n   \nb64enc -\n b64enc -\nb64enc  -\nb64enc\t-\n"))))

(deftest verify-keeps-non-canonical-timestamp-as-data
  (is (= ["fail invalid-timestamp"]
         (run (str "verify " S " " I " 007 1614265400 " H " " P))))
  (is (= ["error"] (run (str "verify " S " " I " 1614265330 007 " H " " P)))))

(def sim-example
  "simulate
endpoint ep_a whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw * 500,timeout,200
endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200
event msg_1 1700000000 user.created 7b7d
event msg_2 1700000100 repo.pushed 7b7d
end
")

(deftest simulate-block
  (is (= ["sim 5 3"
          "attempt 1 msg_1 ep_a 1 1700000000 failure 500"
          "attempt 2 msg_1 ep_b 1 1700000000 success 200"
          "attempt 3 msg_1 ep_a 2 1700000005 timeout -"
          "attempt 4 msg_2 ep_a 1 1700000100 success 200"
          "attempt 5 msg_1 ep_a 3 1700000305 success 200"
          "delivery msg_1 ep_a delivered 3 1700000305 v1,x5lVgj0b/JJJaUYaa1+6I5J/EECcryrPlFN4VrkmI94="
          "delivery msg_1 ep_b delivered 1 1700000000 v1,A5oIrJxXPB/PkULSoVu0e4khvPiqpF9vljmhkSKg0FI= v1,+y5T5nCYgPC5Y9oXnau3uEIax3TN0x8LoF05LBfU83s="
          "delivery msg_2 ep_a delivered 1 1700000100 v1,Cu35wCUZTS4YnAIA1waQmIXPFLh46qYAWpcHufrxa9U="]
         (run sim-example))))

(deftest simulate-errors
  (testing "a malformed block swallows lines up to `end`, then input resumes"
    (is (= ["error" "-"]
           (run "simulate\nendpoint a c2VjcmV0 * 200\nendpoint a c2VjcmV0 * 200\nevent e 0 t -\nend\nb64enc -\n"))))
  (testing "end of input inside a block"
    (is (= ["error"] (run "simulate\nendpoint a c2VjcmV0 * 200\n"))))
  (testing "no endpoints"
    (is (= ["error"] (run "simulate\nend\n"))))
  (testing "endpoint after event"
    (is (= ["error"]
           (run "simulate\nendpoint a c2VjcmV0 * 200\nevent e 0 t -\nendpoint b c2VjcmV0 * 200\nend\n"))))
  (testing "`simulate now` is just a bad command"
    (is (= ["error" "error" "error"] (run "simulate now\nendpoint a c2VjcmV0 * 200\nend\n"))))
  (testing "nested simulate"
    (is (= ["error"] (run "simulate\nsimulate\nendpoint a c2VjcmV0 * 200\nend\n"))))
  (testing "a block with no events is fine"
    (is (= ["sim 0 0"] (run "simulate\nendpoint a c2VjcmV0 * 200\nend\n")))))
