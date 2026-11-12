(ns protowire.schema-test
  (:require [clojure.test :refer [deftest is testing]]
            [protowire.schema :as schema]
            [protowire.test-util :refer [error?]]))

(deftest tokenizing
  (is (= ["message" "A" "{" "int32" "x" "=" "1" ";" "}"]
         (schema/tokenize "message A{int32 x=1;}")))
  (is (= ["message" "A" "{" "}"] (schema/tokenize "\tmessage\r\nA\n{ }"))))

(deftest parsing
  (let [s (schema/parse "message B { repeated A a = 7; int32 z = 2; }
                         message A { B b = 1; }")
        b (schema/message s "B")]
    (testing "fields are sorted by number"
      (is (= [2 7] (map :number (:fields b)))))
    (testing "lookup by number and name"
      (is (= :z (:key (get (:by-number b) 2))))
      (is (= 7 (:number (get (:by-name b) "a")))))
    (testing "recursive/forward message references resolve"
      (is (= "A" (:name (schema/field-message (get (:by-name b) "a")))))
      (is (= "B" (:name (schema/field-message (get (:by-name (schema/message s "A")) "b"))))))
    (testing "repeated numeric fields are packable"
      (let [s (schema/parse "message M { repeated int32 a = 1; repeated string b = 2; int32 c = 3; }")
            f #(get (:by-name (schema/message s "M")) %)]
        (is (:packable? (f "a")))
        (is (not (:packable? (f "b"))))
        (is (not (:packable? (f "c"))))))))

(deftest malformed-schemas
  (is (error? #(schema/parse "message A { int32 x = 1 }")))
  (is (error? #(schema/parse "message A { nope x = 1; }")))
  (is (error? #(schema/parse "message A { int32 x = 1; "))))
