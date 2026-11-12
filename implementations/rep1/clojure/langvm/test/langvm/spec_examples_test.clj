(ns langvm.spec-examples-test
  "The worked examples of SPEC section 17 (extracted verbatim into
  test/resources/spec-examples)."
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.string :as str]
            [langvm.test-util :as u]))

(deftest section-17-examples
  (doseq [^java.io.File in (u/resource-files "spec-examples" ".in")]
    (let [expected (slurp (str/replace (.getPath in) #"\.in$" ".out"))]
      (testing (.getName in)
        (is (u/same-output? expected (u/run (slurp in))))))))
