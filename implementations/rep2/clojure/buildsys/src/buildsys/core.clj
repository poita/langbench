(ns buildsys.core
  "Public API of the Kiln build-system library.

  A *workspace* is a map of workspace path (e.g. \"src/a.txt\") to file
  content.  Content may be given as a `String` (encoded as UTF-8) or a
  `byte[]`; workspaces returned by this namespace hold `byte[]`s.  Use
  `file-text` to read a file as text.

  Typical use:

      (require '[buildsys.core :as kiln])

      (def result
        (kiln/run-session
         {\"main.kiln\" \"step {\\n out \\\"out/a.txt\\\"\\n cmd write(\\\"hi\\\\n\\\")\\n}\\ndefault \\\"out/a.txt\\\"\\n\"}
         \"build\\nbuild\\n\"))
      (:log result)          ; the session log, as a string
      (kiln/file-text (:files result) \"out/a.txt\")  ;=> \"hi\\n\""
  (:require [buildsys.build :as build]
            [buildsys.session :as session]
            [buildsys.vfs :as vfs])
  (:import (java.nio.file Files Paths)))

(defn- ->content ^String [x]
  (cond (string? x) (vfs/utf8->str x)
        (bytes? x)  (vfs/bytes->str x)
        :else (throw (IllegalArgumentException. "file content must be a String or byte[]"))))

(defn- ->vfs [files]
  (reduce-kv (fn [v path content] (vfs/put v path (->content content)))
             (vfs/empty-vfs) files))

(defn- vfs->files [v]
  (into (sorted-map) (map (fn [[p f]] [p (vfs/str->bytes (:content f))])) v))

(defn file-text
  "The content of `path` in workspace `files` decoded as UTF-8, or nil."
  [files path]
  (some-> (get files path) (->content) (vfs/str->utf8)))

(defn build
  "Runs one build of workspace `files` (needs a `main.kiln`).

  Options: `:targets` (a vector of target strings, default: the build's
  default targets) and `:jobs` (worker count, default 1).

  Returns
    :ok?     whether the build succeeded
    :error   on failure, the error text such as \"E_CYCLE a -> b -> a\"
    :ran :hits :time   on success: commands run, cache hits, simulated time
    :events  [{:kind :hit|:run|:fail|:cancel :start :end :worker :target :command}]
    :files   the workspace after the build"
  [files & {:keys [targets jobs] :or {targets [] jobs 1}}]
  (let [r (build/run-build (->vfs files) (vec targets) jobs)]
    (-> r (dissoc :vfs) (assoc :files (vfs->files (:vfs r))))))

(defn run-session
  "Runs a session script (see SPEC.md) against workspace `files`.
  Returns `{:log string, :log-bytes byte[], :files workspace}`."
  [files session-text]
  (let [r (session/run (->vfs files) (session/parse (vfs/utf8->str session-text)))]
    {:log       (vfs/str->utf8 (:log r))
     :log-bytes (vfs/str->bytes (:log r))
     :files     (vfs->files (:vfs r))}))

(defn run-directory
  "The command-line contract: reads `session.txt` and the workspace from
  directory `in-dir`, runs the session and writes `log.txt` and `workspace/`
  into `out-dir`."
  [^String in-dir ^String out-dir]
  (let [workspace (vfs/load-dir in-dir)
        text (vfs/read-file in-dir "session.txt")
        r (session/run workspace (session/parse text))
        out (Paths/get out-dir (make-array String 0))]
    (Files/createDirectories out (make-array java.nio.file.attribute.FileAttribute 0))
    (Files/write (.resolve out "log.txt") (vfs/str->bytes (:log r))
                 (make-array java.nio.file.OpenOption 0))
    (vfs/write-dir! (:vfs r) (str (.resolve out "workspace")))))
