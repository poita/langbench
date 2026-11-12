(ns sitegen.main-test
  (:require [clojure.java.io :as io]
            [clojure.test :refer [deftest is testing]]
            [sitegen.main :as main]
            [sitegen.test-util :as util]))

(defn- temp-dir [] (str (util/temp-dir)))

(deftest command-line
  (let [in (str (io/file (io/resource "sample-site/input")))]
    (testing "success writes the site and returns 0"
      (let [out (temp-dir)]
        (is (= 0 (main/run [in out])))
        (is (.isFile (io/file out "index.html")))
        (is (.isFile (io/file out "feed.xml")))))
    (testing "the output directory is created when missing"
      (let [out (str (io/file (temp-dir) "new" "dir"))]
        (is (= 0 (main/run [in out])))
        (is (.isFile (io/file out "sitemap.xml")))))
    (testing "usage errors return 2"
      (binding [*err* (java.io.StringWriter.)]
        (is (= 2 (main/run [])))
        (is (= 2 (main/run [in])))
        (is (= 2 (main/run [in "a" "b"])))))
    (testing "a missing input returns 1"
      (binding [*err* (java.io.StringWriter.)]
        (is (= 1 (main/run [(str (io/file (temp-dir) "nope")) (temp-dir)])))))))
