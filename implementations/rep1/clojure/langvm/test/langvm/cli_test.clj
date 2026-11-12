(ns langvm.cli-test
  "The tool-level contract of SPEC section 1: one of program output, a panic
  line, or a single diagnostic line."
  (:require [clojure.test :refer [deftest is testing]]
            [langvm.core :as core])
  (:import (java.io ByteArrayOutputStream)))

(defn- execute [text]
  (let [out (ByteArrayOutputStream.)
        status (core/execute text out)]
    [status (.toString out "UTF-8")]))

(deftest statuses
  (is (= [:ok "hi\n"] (execute "@module main\nfn main() { print(\"hi\"); }\n")))
  (is (= [:panic "a\npanic: boom\n"] (execute "@module main\nfn main() { print(\"a\"); panic(\"boom\"); }\n")))
  (is (= [:error "error: parse at 1:1\n"] (execute "@module main\n}\n"))))

(deftest utf-8-output
  (is (= [:ok "h\u00e9llo \uD83D\uDE00\n"]
         (execute "@module main\nfn main() { print(\"h\\u{e9}llo \\u{1F600}\"); }\n"))))

(deftest staged-api
  (let [compiled (core/compile-source "@module main\nfn main() { print(\"x\"); }\n")
        out (ByteArrayOutputStream.)]
    (is (nil? (core/run-compiled compiled out)))
    (is (= "x\n" (.toString out "UTF-8")))
    (testing "a compiled program can run twice"
      (is (nil? (core/run-compiled compiled out)))
      (is (= "x\nx\n" (.toString out "UTF-8"))))))

(deftest panic-message-is-returned
  (let [compiled (core/compile-source "@module main\nfn main() { panic(\"oops\"); }\n")
        out (ByteArrayOutputStream.)]
    (is (= "oops" (core/run-compiled compiled out)))
    (is (= "panic: oops\n" (.toString out "UTF-8")))))
