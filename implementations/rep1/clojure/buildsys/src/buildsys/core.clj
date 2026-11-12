(ns buildsys.core
  "Public API of the Kiln build system library.

  Kiln reads a *workspace* (a virtual file system holding `main.kiln` build
  files and sources), evaluates it into a graph of build steps and executes
  the out-of-date steps on a simulated set of parallel workers.

  A workspace is an immutable sorted map from path string to file; build one
  with [[workspace]] or [[load-workspace]].  All file contents are *byte
  strings*: Java strings with one char (0-255) per byte.  Use [[bytes->str]]
  and [[str->bytes]] to convert.

      (require '[buildsys.core :as kiln])

      (def ws (kiln/workspace {\"main.kiln\" \"step { out \\\"out/a\\\" cmd write(\\\"hi\\\") }\"}))

  [[build]] runs one build and [[run-session]] a whole script of builds and
  edits."
  (:require [buildsys.build :as build]
            [buildsys.session :as session]
            [buildsys.vfs :as vfs])
  (:import (java.nio.charset StandardCharsets)))

(defn bytes->str
  "Convert a byte array to a Kiln byte string."
  ^String [^bytes bs]
  (String. bs StandardCharsets/ISO_8859_1))

(defn str->bytes
  "Convert a Kiln byte string to a byte array."
  ^bytes [^String s]
  (.getBytes s StandardCharsets/ISO_8859_1))

(defn utf8
  "Convert an ordinary (UTF-16) Clojure string to a Kiln byte string holding
  its UTF-8 encoding."
  [^String s]
  (bytes->str (.getBytes s StandardCharsets/UTF_8)))

(defn workspace
  "Create a workspace from a map of path to content (byte strings)."
  [files]
  (reduce-kv vfs/write (vfs/empty-vfs) files))

(defn load-workspace
  "Load the workspace in directory `dir`.  With `skip-session?` the top-level
  `session.txt` is left out."
  ([dir] (load-workspace dir false))
  ([dir skip-session?] (vfs/load-dir dir skip-session?)))

(defn write-workspace
  "Write every file of `workspace` below directory `dir`."
  [workspace dir]
  (vfs/write-dir workspace dir))

(defn files
  "The workspace as a plain map of path to content."
  [workspace]
  (into (sorted-map) (map (fn [[p f]] [p (:content f)])) workspace))

(defn build
  "Run one build of `workspace` for `targets` (a collection of target strings:
  paths or `@phony` names; empty means the default targets) on `workers`
  simulated workers (default 1).

  Returns `{:workspace ws' :events [...] :ran n :hits n :time n :error s}`.
  `:error` is nil on success, otherwise a string such as
  `\"E_MISSING_INPUT src/x required by out/y\"`; after a configuration error
  the workspace is unchanged.  Each event is a map with `:kind` (`:hit`,
  `:run`, `:fail` or `:cancel`), `:start`, `:end`, `:worker`, `:target`
  and `:cmd`."
  ([workspace targets] (build workspace targets 1))
  ([workspace targets workers]
   (let [r (build/build workspace (vec targets) workers)]
     (-> r (assoc :workspace (:vfs r)) (dissoc :vfs)))))

(defn parse-session
  "Parse the text of a `session.txt` into a vector of session steps."
  [text]
  (session/parse-session text))

(defn run-session
  "Run a session script (text) against `workspace`.  Returns
  `{:log string :workspace ws'}` where `:log` is the content of `log.txt`."
  [workspace session-text]
  (let [r (session/run-session workspace (session/parse-session session-text))]
    {:log (:log r) :workspace (:vfs r)}))
