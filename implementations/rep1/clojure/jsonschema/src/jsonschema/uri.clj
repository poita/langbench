(ns jsonschema.uri
  "RFC 3986 URI-reference parsing and resolution, percent-decoding, and RFC
  6901 JSON Pointer evaluation. Written by hand: no regular expressions."
  (:require [clojure.string :as str])
  (:import (java.io ByteArrayOutputStream)
           (java.nio.charset StandardCharsets)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Parsing and recomposition

(defn- scheme-char? [c]
  (or (Character/isLetterOrDigit (int c)) (= c \+) (= c \-) (= c \.)))

(defn- scheme-end
  "Index of the `:` ending a leading scheme in `s`, or nil."
  [^String s]
  (when (and (pos? (.length s)) (Character/isLetter (.charAt s 0)))
    (loop [i 1]
      (when (< i (.length s))
        (let [c (.charAt s i)]
          (cond (= c \:) i
                (scheme-char? c) (recur (inc i))
                :else nil))))))

(defn parse
  "Splits a URI reference into `{:scheme :authority :path :query :fragment}`.
  Absent components are `nil`; `:path` is always a string (possibly empty)."
  [^String ref]
  (let [hash-i (.indexOf ref "#")
        fragment (when (>= hash-i 0) (.substring ref (inc hash-i)))
        ref (if (>= hash-i 0) (.substring ref 0 hash-i) ref)
        q-i (.indexOf ref "?")
        query (when (>= q-i 0) (.substring ref (inc q-i)))
        ref (if (>= q-i 0) (.substring ref 0 q-i) ref)
        s-i (scheme-end ref)
        scheme (when s-i (.substring ref 0 (int s-i)))
        ref (if s-i (.substring ref (inc (int s-i))) ref)
        [authority path] (if (.startsWith ref "//")
                           (let [rest (.substring ref 2)
                                 slash (.indexOf rest "/")]
                             (if (>= slash 0)
                               [(.substring rest 0 slash) (.substring rest slash)]
                               [rest ""]))
                           [nil ref])]
    {:scheme scheme :authority authority :path path :query query :fragment fragment}))

(defn recompose
  "Inverse of [[parse]] (RFC 3986 section 5.3)."
  [{:keys [scheme authority path query fragment]}]
  (str (when scheme (str scheme ":"))
       (when authority (str "//" authority))
       path
       (when query (str "?" query))
       (when fragment (str "#" fragment))))

(defn remove-dot-segments
  "RFC 3986 section 5.2.4."
  [^String path]
  (loop [in path, out []]
    (cond
      (empty? in) (apply str out)
      (.startsWith ^String in "../") (recur (subs in 3) out)
      (.startsWith ^String in "./") (recur (subs in 2) out)
      (.startsWith ^String in "/./") (recur (subs in 2) out)
      (= in "/.") (recur "/" out)
      (.startsWith ^String in "/../") (recur (subs in 3) (if (seq out) (pop out) out))
      (= in "/..") (recur "/" (if (seq out) (pop out) out))
      (or (= in ".") (= in "..")) (recur "" out)
      :else (let [from (if (.startsWith ^String in "/") 1 0)
                  slash (.indexOf ^String in "/" (int from))
                  end (if (neg? slash) (count in) slash)]
              (recur (subs in end) (conj out (subs in 0 end)))))))

(defn- merge-paths [base-parsed ^String ref-path]
  (if (and (some? (:authority base-parsed)) (= "" (:path base-parsed)))
    (str "/" ref-path)
    (let [^String bp (:path base-parsed)
          i (.lastIndexOf bp "/")]
      (str (if (neg? i) "" (.substring bp 0 (inc i))) ref-path))))

(defn resolve-reference
  "Resolves the URI reference `ref` against `base` (both strings) following
  RFC 3986 section 5.2.2 (strict), and returns the target URI as a string."
  [base ref]
  (let [r (parse ref)
        b (parse base)]
    (recompose
     (cond
       (:scheme r) (assoc r :path (remove-dot-segments (:path r)))
       (some? (:authority r)) (assoc r :scheme (:scheme b)
                                     :path (remove-dot-segments (:path r)))
       (= "" (:path r)) {:scheme (:scheme b) :authority (:authority b) :path (:path b)
                         :query (if (some? (:query r)) (:query r) (:query b))
                         :fragment (:fragment r)}
       :else {:scheme (:scheme b) :authority (:authority b)
              :path (remove-dot-segments
                     (if (.startsWith ^String (:path r) "/")
                       (:path r)
                       (merge-paths b (:path r))))
              :query (:query r) :fragment (:fragment r)}))))

(defn strip-fragment
  "Removes the fragment (and its `#`) from a URI reference string."
  [^String uri]
  (let [i (.indexOf uri "#")]
    (if (neg? i) uri (.substring uri 0 i))))

(defn split-fragment
  "Splits a URI string into `[document-part fragment]`; the fragment is nil
  when there is no `#`."
  [^String uri]
  (let [i (.indexOf uri "#")]
    (if (neg? i) [uri nil] [(.substring uri 0 i) (.substring uri (inc i))])))

;; ---------------------------------------------------------------------------
;; Percent-decoding

(defn percent-decode
  "Decodes `%HH` escapes in `s` as UTF-8. Malformed escapes are kept as is."
  [^String s]
  (if (neg? (.indexOf s "%"))
    s
    (let [bos (ByteArrayOutputStream.)
          n (.length s)]
      (loop [i 0]
        (when (< i n)
          (let [c (.charAt s i)]
            (if (and (= c \%) (<= (+ i 3) n)
                     (>= (Character/digit (.charAt s (+ i 1)) 16) 0)
                     (>= (Character/digit (.charAt s (+ i 2)) 16) 0))
              (do (.write bos (+ (* 16 (Character/digit (.charAt s (+ i 1)) 16))
                                 (Character/digit (.charAt s (+ i 2)) 16)))
                  (recur (+ i 3)))
              (let [cp (.codePointAt s i)
                    chars (Character/charCount cp)]
                (.write bos (.getBytes (.substring s i (+ i chars)) StandardCharsets/UTF_8))
                (recur (+ i chars)))))))
      (String. (.toByteArray bos) StandardCharsets/UTF_8))))

;; ---------------------------------------------------------------------------
;; JSON Pointer (RFC 6901)

(defn pointer-segments
  "Splits a JSON Pointer (which must be empty or start with `/`) into its
  unescaped reference tokens."
  [^String pointer]
  (if (= "" pointer)
    []
    (let [^String body (subs pointer 1)]
      (loop [from 0, out []]
        (let [i (.indexOf body "/" (int from))
              tok (if (neg? i) (.substring body from) (.substring body from i))
              tok (-> tok (str/replace "~1" "/") (str/replace "~0" "~"))]
          (if (neg? i) (conj out tok) (recur (inc i) (conj out tok))))))))

(defn pointer-get
  "Evaluates the JSON Pointer string `pointer` against the JSON value `doc`.
  Returns `[:found value]` or `nil` when the pointer does not resolve."
  [doc pointer]
  (loop [v doc, [seg & more :as segs] (seq (pointer-segments pointer))]
    (if-not segs
      [:found v]
      (cond
        (map? v) (when (contains? v seg) (recur (get v seg) more))
        (vector? v) (when (and (seq seg) (every? #(Character/isDigit (char %)) seg)
                               (or (= seg "0") (not= (first seg) \0)))
                      (let [i (parse-long seg)]
                        (when (and i (< i (count v))) (recur (nth v i) more))))
        :else nil))))
