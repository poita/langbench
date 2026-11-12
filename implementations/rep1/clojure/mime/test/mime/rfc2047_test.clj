(ns mime.rfc2047-test
  (:require [clojure.test :refer [deftest are is]]
            [mime.rfc2047 :as r]))

(deftest unstructured-examples
  (are [in out] (= out (r/decode-unstructured in))
    "=?utf-8?Q?caf=C3=A9?="                     "café"
    "=?utf-8?Q?a?=   =?utf-8?Q?b?="             "ab"
    "x =?utf-8?Q?a?= y"                         "x a y"
    "=?utf-8?Q?a?=b"                            "ab"
    "=?iso-8859-1?Q?caf=E9?="                   "café"
    "=?windows-1252?Q?smart=92quote?="          "smart’quote"
    "=?utf-8?B?SsO2cmc=?="                      "Jörg"
    "=?utf-8*en?Q?hi?="                         "hi"
    "=?utf-8?X?hi?="                            "=?utf-8?X?hi?="
    "  plain    spaced   text  "                "plain    spaced   text"
    "=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c"       "ab \t c"
    "=?utf-8?Q?a_b?="                           "a b"))

(deftest display-examples
  (are [in out] (= out (r/decode-display in))
    "John Q. Public "                  "John Q. Public"
    "\"Doe, John\" "                   "Doe, John"
    "=?utf-8?B?SsO2cmc=?= "            "Jörg"
    "John (the third) Public "         "John   Public"
    "\"=?utf-8?Q?x?=\" "               "=?utf-8?Q?x?="))

(deftest encoded-word-recognition
  (is (= [13 "a"] (r/encoded-word-at "=?utf-8?Q?a?=" 0)))
  (is (nil? (r/encoded-word-at "=?utf-8?Q?a b?=" 0)) "blank inside encoded text")
  (is (nil? (r/encoded-word-at "=??Q?a?=" 0)) "empty charset")
  (is (nil? (r/encoded-word-at "=?utf-8?Q?a?" 0)) "missing final ="))
