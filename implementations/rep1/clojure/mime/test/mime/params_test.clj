(ns mime.params-test
  (:require [clojure.test :refer [deftest are is]]
            [mime.params :as p]))

(defn- filename [raw] (get (:params (p/parse (str "attachment; " raw))) "filename"))

(deftest value-and-params
  (let [r (p/parse " Text/Plain ; Charset=\"UTF-8\"; x=1; x=2")]
    (is (= "text/plain" (:value r)))
    (is (= {"charset" "UTF-8" "x" "1"} (:params r)))))

(deftest quoting
  (are [raw out] (= out (filename raw))
    "filename=\"report.pdf\""         "report.pdf"
    "filename=two words.bin"          "two words.bin"
    "filename=\"a\\\\\"; x=1"         "a\\"
    "filename=\"semi;colon\""         "semi;colon"
    "filename=\"=?utf-8?Q?a=C3=A9.txt?=\"" "aé.txt"))

(deftest rfc2231
  (are [raw out] (= out (filename raw))
    "filename*=utf-8''a%C3%A9.txt"                        "aé.txt"
    "filename*0=\"long\"; filename*1=\"name.txt\""        "longname.txt"
    "filename*0*=utf-8''a%C3%A9; filename*1=\".txt\""     "aé.txt"
    "filename*=''caf%E9.txt"                              "caf�.txt"
    "filename*0=a; filename*2=c; filename*10=j"           "acj"
    "filename=plain; filename*=utf-8''ext"                "ext"
    "filename*=utf-8''ext; filename*0=num"                "num"
    "filename*0=first; filename*00=second"                "first"))

(deftest star-names-are-plain
  (is (= "x" (get (:params (p/parse "a; *0=x")) "*0"))))
