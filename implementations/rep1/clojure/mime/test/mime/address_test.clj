(ns mime.address-test
  (:require [clojure.test :refer [deftest are is]]
            [mime.address :as a]))

(defn- parse [v] (mapv (juxt :display :spec) (a/parse-list v)))

(deftest address-examples
  (are [v out] (= out (parse v))
    "Real Name <user@example.com>"            [["Real Name" "user@example.com"]]
    "user@example.com (Real Name)"            [["" "user@example.com"]]
    "\"Doe, John\" <jd@x.com>"                [["Doe, John" "jd@x.com"]]
    "a@b.com, (c) d@e.com"                    [["" "a@b.com"] ["" "d@e.com"]]
    "Undisclosed recipients:;"                []
    "grp: a@b.com, c@d.com;"                  [["" "a@b.com"] ["" "c@d.com"]]
    "=?utf-8?B?SsO2cmc=?= <j@x.de>"           [["Jörg" "j@x.de"]]
    "foo (c (nested)) <a@b>"                  [["foo" "a@b"]]
    "ed <a@[10.0.0.1]>"                       [["ed" "a@[10.0.0.1]"]]
    "broken <a@@b>"                           [["" "broken<a@@b>"]]
    "John Q. Public <jqp@example.com>"        [["John Q. Public" "jqp@example.com"]]
    "Symantec Email Proxy"                    [["" "SymantecEmailProxy"]]
    "\"=?utf-8?Q?x?=\" <a@b>"                 [["=?utf-8?Q?x?=" "a@b"]]
    "a <b <c@d.com> , e@f.com>, g@h.com"      [["" "a<b<c@d.com>,e@f.com>"] ["" "g@h.com"]]
    "John (the third) Public <jqp@x.com>"     [["John   Public" "jqp@x.com"]]
    ""                                        []))

(deftest tokens
  (is (= [:atom :special :atom] (mapv :type (a/tokenize "a@b"))))
  (is (= [:encoded] (mapv :type (a/tokenize "=?utf-8?Q?a=40b?="))))
  (is (= "[a\\]b]" (:text (first (a/tokenize "[a\\]b]"))))))
