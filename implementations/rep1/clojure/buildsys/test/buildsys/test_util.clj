(ns buildsys.test-util
  "Helpers shared by the test namespaces."
  (:require [buildsys.core :as kiln]))

(defn ws
  "A workspace from a map of path to (UTF-8) text content."
  [files]
  (kiln/workspace (update-vals files kiln/utf8)))

(defn session-log
  "Run `session` (text) against a workspace of `files`; returns the log text."
  [files session]
  (:log (kiln/run-session (ws files) session)))

(defn build-error
  "The error string of building `files` for `targets`, or nil."
  ([files] (build-error files []))
  ([files targets] (:error (kiln/build (ws files) targets))))

(defn eval-expr
  "Evaluate KBL expression text `expr` (after `prelude` lines) by aborting with
  its interpolated value; returns the abort message, or the error string for
  any other error."
  ([expr] (eval-expr "" expr))
  ([prelude expr]
   (let [err (build-error {"main.kiln" (str prelude "\nabort \"{" expr "}\"\n")})]
     (if-let [[_ m] (re-matches #"(?s)E_ABORT (.*)" err)] m err))))

(defn tmp-dir
  "A fresh temporary directory (a path string).  Honours `$TMPDIR`."
  [prefix]
  (let [base (or (System/getenv "TMPDIR") (System/getProperty "java.io.tmpdir"))]
    (str (java.nio.file.Files/createTempDirectory
          (java.nio.file.Paths/get base (make-array String 0))
          prefix
          (make-array java.nio.file.attribute.FileAttribute 0)))))

(defn file
  "Content of `path` in the workspace of result `r`."
  [r path]
  (get (kiln/files (:workspace r)) path))
