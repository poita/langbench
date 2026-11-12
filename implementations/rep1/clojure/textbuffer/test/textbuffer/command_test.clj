(ns textbuffer.command-test
  (:require [clojure.test :refer [deftest is testing]]
            [textbuffer.buffer :as b]
            [textbuffer.command :as cmd]))

(deftest decoding
  (is (= "a\nb" (cmd/decode-insert-text "a\\nb")))
  (is (= "a\\b" (cmd/decode-insert-text "a\\\\b")))
  (is (= "\\n" (cmd/decode-insert-text "\\\\n")))
  (is (= "  x  " (cmd/decode-insert-text "  x  ")))
  (is (= "\n\n" (cmd/decode-insert-text "\\n\\n"))))

(deftest parsing
  (is (= {:op :insert :text " hi "} (cmd/parse "insert  hi ")))
  (is (= {:op :insert :text "a b\nc"} (cmd/parse "insert a b\\nc")))
  (is (= {:op :delete} (cmd/parse "delete")))
  (is (= {:op :delete-forward} (cmd/parse "delete-forward")))
  (is (= {:op :move :dir :home :select? false} (cmd/parse "move home")))
  (is (= {:op :move :dir :up :select? true} (cmd/parse "move up select")))
  (is (= {:op :goto :line 3 :col 1000000000} (cmd/parse "goto 3 1000000000")))
  (is (= {:op :add-cursor :line 0 :col 0} (cmd/parse "add-cursor 0 0")))
  (is (= [{:op :clear-cursors} {:op :undo} {:op :redo} {:op :print}]
         (mapv cmd/parse ["clear-cursors" "undo" "redo" "print"]))))

(deftest parse-errors
  (doseq [bad ["" "frobnicate" "move" "move sideways" "move left now" "goto 1"
               "goto a b" "insert" "add-cursor 1"]]
    (testing bad
      (is (thrown? clojure.lang.ExceptionInfo (cmd/parse bad))))))

(deftest execution
  (let [out (java.io.StringWriter.)
        buf (reduce (fn [buf line] (cmd/execute buf (cmd/parse line) out))
                    (b/from-text "ab")
                    ["move end" "insert c" "print" "undo" "print"])]
    (is (= "abc\ncursor 0 3\n--\nab\ncursor 0 2\n--\n" (str out)))
    (is (= ["ab"] (b/lines buf)))))
