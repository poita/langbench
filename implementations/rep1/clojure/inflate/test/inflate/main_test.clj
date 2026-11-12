(ns inflate.main-test
  (:require [clojure.test :refer [deftest is are]]
            [inflate.main :as main])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)))

(defn- cli [^String input]
  (let [out (ByteArrayOutputStream.)]
    (main/run (ByteArrayInputStream. (.getBytes input "US-ASCII")) out)
    (.toString out "US-ASCII")))

(deftest cli-contract
  (are [in out] (= out (cli in))
    "0300\n" "\n"
    "4b4c4a862000\n" "616263616263616263\n"
    "010100feff41\n" "41\n"
    "030200\n" "error\n"
    "\n" "error\n"
    "" "error\n"))
