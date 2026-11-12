(ns jsonschema.uri-test
  (:require [clojure.test :refer [deftest is are]]
            [jsonschema.uri :as uri]))

(deftest rfc3986-normal-examples
  ;; RFC 3986 section 5.4.1, base http://a/b/c/d;p?q
  (are [ref expected] (= expected (uri/resolve-reference "http://a/b/c/d;p?q" ref))
    "g:h" "g:h"
    "g" "http://a/b/c/g"
    "./g" "http://a/b/c/g"
    "g/" "http://a/b/c/g/"
    "/g" "http://a/g"
    "//g" "http://g"
    "?y" "http://a/b/c/d;p?y"
    "g?y" "http://a/b/c/g?y"
    "#s" "http://a/b/c/d;p?q#s"
    "g#s" "http://a/b/c/g#s"
    "g?y#s" "http://a/b/c/g?y#s"
    ";x" "http://a/b/c/;x"
    "" "http://a/b/c/d;p?q"
    "." "http://a/b/c/"
    "./" "http://a/b/c/"
    ".." "http://a/b/"
    "../" "http://a/b/"
    "../g" "http://a/b/g"
    "../.." "http://a/"
    "../../" "http://a/"
    "../../g" "http://a/g"))

(deftest rfc3986-abnormal-examples
  (are [ref expected] (= expected (uri/resolve-reference "http://a/b/c/d;p?q" ref))
    "../../../g" "http://a/g"
    "../../../../g" "http://a/g"
    "/./g" "http://a/g"
    "/../g" "http://a/g"
    "g." "http://a/b/c/g."
    ".g" "http://a/b/c/.g"
    "g.." "http://a/b/c/g.."
    "..g" "http://a/b/c/..g"
    "./../g" "http://a/b/g"
    "./g/." "http://a/b/c/g/"
    "g/./h" "http://a/b/c/g/h"
    "g/../h" "http://a/b/c/h"
    "g;x=1/./y" "http://a/b/c/g;x=1/y"
    "g;x=1/../y" "http://a/b/c/y"
    "g?y/./x" "http://a/b/c/g?y/./x"
    "g#s/../x" "http://a/b/c/g#s/../x"
    "http:g" "http:g"))

(deftest non-hierarchical-and-empty-bases
  (is (= "urn:uuid:1234#/$defs/x" (uri/resolve-reference "urn:uuid:1234" "#/$defs/x")))
  (is (= "urn:uuid:other" (uri/resolve-reference "urn:uuid:1234" "urn:uuid:other")))
  (is (= "#foo" (uri/resolve-reference "" "#foo")))
  (is (= "foo.json" (uri/resolve-reference "" "foo.json")))
  (is (= "http://x/y/z.json" (uri/resolve-reference "http://x/y/" "z.json")))
  (is (= "http://x/z.json" (uri/resolve-reference "http://x" "z.json"))))

(deftest fragments
  (is (= "http://x/y" (uri/strip-fragment "http://x/y#frag")))
  (is (= ["http://x/y" "frag"] (uri/split-fragment "http://x/y#frag")))
  (is (= ["http://x/y" ""] (uri/split-fragment "http://x/y#")))
  (is (= ["http://x/y" nil] (uri/split-fragment "http://x/y"))))

(deftest percent-decoding
  (is (= "a b" (uri/percent-decode "a%20b")))
  (is (= "é" (uri/percent-decode "%C3%A9")))
  (is (= "%zz" (uri/percent-decode "%zz")))
  (is (= "100%" (uri/percent-decode "100%")))
  (is (= "💩" (uri/percent-decode "%F0%9F%92%A9")))
  (is (= "plain💩%" (uri/percent-decode "plain💩%25"))))

(deftest json-pointer
  (let [doc {"a" {"b" [10 20 {"c/d" 1 "e~f" 2}]} "" 3}]
    (is (= [:found doc] (uri/pointer-get doc "")))
    (is (= [:found 20] (uri/pointer-get doc "/a/b/1")))
    (is (= [:found 1] (uri/pointer-get doc "/a/b/2/c~1d")))
    (is (= [:found 2] (uri/pointer-get doc "/a/b/2/e~0f")))
    (is (= [:found 3] (uri/pointer-get doc "/")))
    (is (nil? (uri/pointer-get doc "/a/b/3")))
    (is (nil? (uri/pointer-get doc "/a/b/01")))
    (is (nil? (uri/pointer-get doc "/a/x")))
    (is (nil? (uri/pointer-get doc "/a/b/1/z")))))
