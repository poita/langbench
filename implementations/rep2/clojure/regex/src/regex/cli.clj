(ns regex.cli
  "Command line front end.

  Reads the problem described in the README from stdin: a pattern count N,
  then for each pattern the pattern line, a subject count M and M subject
  lines.  For each subject writes `no` or `match <start> <end>|gs,ge|-...`."
  (:require [regex.core :as core]
            [regex.vm :as vm])
  (:import (java.io InputStream OutputStream))
  (:gen-class))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(definterface ILines
  (^long nextLine [])
  (^chars chars []))

(deftype LineReader [^InputStream in ^bytes buf
                     ^:unsynchronized-mutable ^long pos
                     ^:unsynchronized-mutable ^long lim
                     ^:unsynchronized-mutable ^chars line]
  ILines
  (chars [_] line)
  (nextLine [_]
    ;; Returns the length of the next line (without its newline) in `line`,
    ;; or -1 at end of input.
    (loop [n 0]
      (if (>= pos lim)
        (let [k (.read in buf 0 (alength buf))]
          (if (neg? k)
            (if (zero? n) -1 n)
            (do (set! pos (long 0)) (set! lim (long k)) (recur n))))
        (let [b (aget buf pos)]
          (set! pos (inc pos))
          (if (== b 10)
            n
            (do (when (>= n (alength line))
                  (set! line (java.util.Arrays/copyOf line (* 2 (alength line)))))
                (aset line n (char (bit-and b 0xff)))
                (recur (inc n)))))))))

(defn line-reader
  "A reader of newline-terminated ASCII lines from `in`."
  [^InputStream in]
  (->LineReader in (byte-array 65536) 0 0 (char-array 1024)))

(defn- read-count [^regex.cli.ILines r]
  (let [n (.nextLine r)
        ^chars cs (.chars r)]
    (when (neg? n) (throw (ex-info "Unexpected end of input" {})))
    (Long/parseLong (String. cs 0 (int n)))))

(defn- append-result [^StringBuilder sb ^ints out ^long ngroups]
  (.append sb "match ")
  (.append sb (aget out 0))
  (.append sb \space)
  (.append sb (aget out 1))
  (dotimes [g ngroups]
    (let [gs (aget out (+ 2 (* 2 g)))]
      (.append sb \|)
      (if (neg? gs)
        (.append sb \-)
        (do (.append sb gs)
            (.append sb \,)
            (.append sb (aget out (+ 3 (* 2 g)))))))))

(defn run
  "Processes the whole problem from `in`, writing the report to `out`."
  [^InputStream in ^OutputStream out]
  (let [^regex.cli.ILines r (line-reader in)
        sb (StringBuilder. 1048576)
        flush! (fn [] (.write out (.getBytes (.toString sb) "ISO-8859-1"))
                 (.setLength sb 0))
        n (read-count r)]
    (dotimes [_ n]
      (let [plen (.nextLine r)
            _ (when (neg? plen) (throw (ex-info "Unexpected end of input" {})))
            re (core/compile (String. ^chars (.chars r) 0 (int plen)))
            prog (:program re)
            ngroups (long (:group-count re))
            ws (vm/workspace prog)
            res (int-array (vm/result-size prog))
            m (read-count r)]
        (dotimes [_ m]
          (let [len (.nextLine r)
                _ (when (neg? len) (throw (ex-info "Unexpected end of input" {})))]
            (if (vm/search prog ws (.chars r) len res)
              (append-result sb res ngroups)
              (.append sb "no"))
            (.append sb \newline)
            (when (> (.length sb) 1000000) (flush!))))))
    (flush!)
    (.flush out)))

(defn -main
  "Entry point: reads stdin, writes stdout."
  [& _]
  (try
    (run System/in (java.io.FileOutputStream. java.io.FileDescriptor/out))
    (catch Throwable t
      (binding [*out* *err*] (println "error:" (ex-message t)))
      (System/exit 1)))
  (shutdown-agents))
