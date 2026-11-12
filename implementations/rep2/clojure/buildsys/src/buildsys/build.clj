(ns buildsys.build
  "One `build` of a session: evaluate the build files, validate the graph,
  find the reachable set, then schedule and execute, then persist the state."
  (:require [buildsys.errors :as e]
            [buildsys.eval :as eval]
            [buildsys.graph :as graph]
            [buildsys.scheduler :as scheduler]
            [buildsys.state :as state]
            [buildsys.vfs :as vfs]
            [clojure.string :as str]))

(def main-file "main.kiln")

(defn- dedupe-keep-first [xs] (vec (distinct xs)))

(defn- configure
  "Phases 1-5.  Returns {:graph :reachable} or throws a Kiln error."
  [vfs targets]
  (when-not (vfs/exists? vfs main-file) (e/fail! "E_NO_BUILD_FILE" main-file))
  (let [g (graph/build (eval/evaluate vfs main-file) vfs)
        requested (if (seq targets) (dedupe-keep-first targets) (dedupe-keep-first (:defaults g)))]
    (when (empty? requested) (e/fail! "E_NO_DEFAULT"))
    (let [roots (graph/resolve-targets g requested)]
      {:graph g :reachable (graph/find-cycle-or-reach g roots)})))

(defn run-build
  "Runs one build of workspace `vfs` for `targets` (strings) on `jobs` workers.

  Returns a map
    {:vfs     the workspace after the build
     :events  [{:serial :kind :start :end :worker :target :command} ...]
     :ok?     true when the build succeeded
     :ran :hits :time   (on success)
     :error   the error text, e.g. \"E_CYCLE a -> b -> a\" (on failure)}
  Configuration errors leave the workspace untouched and produce no events."
  [vfs targets jobs]
  (try
    (let [{:keys [graph reachable]} (configure vfs targets)
          steps (:steps graph)
          start-state (state/parse (vfs/content vfs vfs/state-path))
          result (scheduler/run graph reachable vfs start-state jobs)
          final-vfs (vfs/put (:vfs result) vfs/state-path (state/render (:state result)))
          events (mapv (fn [ev]
                         (let [step (nth steps (:serial ev))]
                           (assoc ev :target (:primary step) :command (:cmd-str step))))
                       (:events result))]
      (if-let [err (:error result)]
        {:vfs final-vfs :events events :ok? false :error (e/render err)}
        {:vfs final-vfs :events events :ok? true
         :ran (:ran result) :hits (:hits result) :time (:time result)}))
    (catch clojure.lang.ExceptionInfo ex
      (if (e/kiln-error? ex)
        {:vfs vfs :events [] :ok? false :error (e/render ex)}
        (throw ex)))))
