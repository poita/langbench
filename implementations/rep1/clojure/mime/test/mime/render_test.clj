(ns mime.render-test
  (:require [clojure.test :refer [deftest are is]]
            [mime.render :as r]))

(deftest escaping
  (are [in out] (= out (r/esc in))
    "a\\b"      "a\\\\b"
    "l1\nl2\r"  "l1\\nl2\\r"
    "t\tq\""    "t\\tq\\\""
    "\u0001\u007f\u0085" "\\x01\\x7f\\x85"
    "é€"        "é€")
  (is (= "\"x\"" (r/q "x"))))
