(ns buildsys.build
  "One `build` of a workspace: configuration (phases 1-5), then scheduling and
  execution, then writing the state file.  See SPEC.md, \"The build
  algorithm\"."
  (:require [buildsys.error :as err]
            [buildsys.eval :as eval]
            [buildsys.graph :as graph]
            [buildsys.scheduler :as scheduler]
            [buildsys.state :as state]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(def main-file "main.kiln")

(defn build
  "Run one build of `vfs` for `targets` (a vector of target strings; empty means
  the default targets) on `workers` simulated workers.

  Returns a map:

  - `:vfs`    the resulting file system (unchanged after a configuration error);
  - `:events` the log events, see [[buildsys.scheduler/run]];
  - `:ran`, `:hits`, `:time` the summary counters (nil after a configuration error);
  - `:error`  the error text `\"E_KIND detail\"`, or nil on success."
  [vfs targets workers]
  (try
    (when-not (vfs/exists? vfs main-file)
      (err/fail "E_NO_BUILD_FILE" main-file))
    (let [evaluated (eval/evaluate vfs main-file)
          g (graph/build-graph evaluated vfs)
          roots (graph/requested-targets g targets)
          reachable (graph/reachable g roots)
          entries (state/read-state (vfs/content vfs state/state-path))
          result (scheduler/run g reachable workers vfs entries)]
      {:vfs (vfs/write (:vfs result) state/state-path (state/write-state (:entries result)))
       :events (:events result)
       :ran (:ran result)
       :hits (:hits result)
       :time (:time result)
       :error (some-> (:error result) err/render)})
    (catch clojure.lang.ExceptionInfo e
      (if (err/kiln-error? e)
        {:vfs vfs :events [] :error (err/render e)}
        (throw e)))))
