(ns commonmark.main-test
  (:require [clojure.test :refer [deftest is]]
            [commonmark.main :as main])
  (:import (java.io ByteArrayInputStream ByteArrayOutputStream)
           (java.nio.charset StandardCharsets)))

(defn- run [^String input]
  (let [out (ByteArrayOutputStream.)]
    (main/convert-stream (ByteArrayInputStream. (.getBytes input StandardCharsets/UTF_8)) out)
    (String. (.toByteArray out) StandardCharsets/UTF_8)))

(deftest stdin-to-stdout
  (is (= "" (run "")))
  (is (= "<h1>Grüße €</h1>\n<p>😀 <em>ok</em></p>\n" (run "# Grüße €\n\n😀 *ok*\n"))))
