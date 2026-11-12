(ns depresolve.cli-test
  (:require [clojure.test :refer [deftest is]]
            [depresolve.cli :as cli])
  (:import (java.io StringReader)))

(defn- run-cli [input]
  (binding [*in* (clojure.lang.LineNumberingPushbackReader. (StringReader. input))]
    (with-out-str (cli/-main))))

(deftest stdin-to-stdout
  (is (= "a 1.0.0\nb 2.0.0\n"
         (run-cli "a 1.0.0: b *\nb 1.0.0:\nb 2.0.0:\nroot: a *\n")))
  (is (= "unsatisfiable\n" (run-cli "root: x *\n")))
  (is (= "" (run-cli "root:\n"))))
