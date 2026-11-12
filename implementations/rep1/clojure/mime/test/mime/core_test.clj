(ns mime.core-test
  "End-to-end tests: whole messages and whole mailboxes through the dump."
  (:require [clojure.java.io :as io]
            [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [mime.core :as mime])
  (:import (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defn- tmp-dir []
  (let [base (some-> (System/getenv "TMPDIR") io/file .toPath)]
    (.toFile (if base
               (Files/createTempDirectory base "mime-test" (make-array FileAttribute 0))
               (Files/createTempDirectory "mime-test" (make-array FileAttribute 0))))))

(defn- tree
  "Map from relative path to content (string for .txt, byte vector otherwise)."
  [^java.io.File root]
  (into {}
        (for [^java.io.File f (file-seq root) :when (.isFile f)
              :let [rel (str (.relativize (.toPath root) (.toPath f)))]]
          [rel (if (str/ends-with? rel ".txt")
                 (slurp f :encoding "UTF-8")
                 (vec (Files/readAllBytes (.toPath f))))])))

(deftest worked-example
  (let [out (tmp-dir)]
    (mime/convert! (io/file (io/resource "worked-example/input")) out)
    (is (= (tree (io/file (io/resource "worked-example/expected"))) (tree out)))))

(deftest crlf-directory
  (let [out (tmp-dir)]
    (mime/convert! (io/file (io/resource "crlf/input")) out)
    (is (= (tree (io/file (io/resource "crlf/expected"))) (tree out)))))

(deftest parse-message-data
  (let [msg (mime/parse-message
             (.getBytes (str "Subject: =?utf-8?Q?hi?=\n"
                             "From: A <a@b.c>\n"
                             "Date: 1 Jan 2000 00:00:00 +0000\n"
                             "Content-Type: multipart/mixed; boundary=z\n\n"
                             "--z\nContent-Type: text/plain\n\nhello\n"
                             "--z\nContent-Type: application/x\n"
                             "Content-Disposition: attachment; filename=f.bin\n\nxx\n--z--\n")
                        "UTF-8"))]
    (is (= 3 (count (:parts msg))))
    (is (= 1 (:text msg)))
    (is (nil? (:html msg)))
    (is (= ["f.bin"] (map :filename (:attachments msg))))
    (is (= [{:display "A" :spec "a@b.c"}] (get-in msg [:addresses "from"])))
    (is (= 946684800 (get-in msg [:date :epoch])))))
