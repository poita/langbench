(ns buildsys.scheduler
  "The deterministic scheduling simulation.

  [[run]] simulates the reachable steps of a build graph on `N` workers with an
  integer clock, deciding freshness when steps become ready, dispatching stale
  ones lowest serial first onto the lowest free worker, and executing commands
  against the virtual file system.  Ready sets are sorted sets keyed by serial
  number, so every ready-set operation is O(log R)."
  (:require [buildsys.commands :as commands]
            [buildsys.error :as err]
            [buildsys.graph :as graph]
            [buildsys.state :as state]
            [buildsys.vfs :as vfs]))

(set! *warn-on-reflection* true)

(defn run
  "Simulate a build.

  Arguments: the `graph` (from [[buildsys.graph/build-graph]]), the set of
  `reachable` nodes, the number of `workers`, the file system `vfs` and the
  `entries` of the state file as read.

  Returns a map with `:events` (sorted by start time then serial; each a map
  with `:kind` of `:hit`, `:run`, `:fail` or `:cancel`, plus `:serial :start
  :end :worker :target :cmd`), `:ran`, `:hits`, `:time`, `:error` (an
  exception, or nil), and the resulting `:vfs` and `:entries`."
  [graph reachable workers vfs entries]
  (let [steps (:steps graph)
        succs (into {} (map (fn [n] [n (vec (graph/successors graph n))]) reachable))
        dependents (let [m (java.util.HashMap.)]
                     (doseq [[n ss] succs, s ss]
                       (.put m s (conj (or (.get m s) []) n)))
                     m)
        pending (java.util.HashMap.)
        _ (doseq [[n ss] succs] (.put pending n (count ss)))
        undecided (volatile! (sorted-set))   ; ready, no freshness decision yet
        ready (volatile! (sorted-set))       ; ready and stale
        free (volatile! (into (sorted-set) (range workers)))
        running (volatile! (sorted-map))     ; worker -> {:serial :start :end :result}
        vfs (volatile! vfs)
        entries (volatile! entries)
        events (volatile! {})                ; serial -> event
        ran (volatile! 0)
        hits (volatile! 0)
        max-time (volatile! 0)
        error (volatile! nil)]
    (letfn [(complete! [node]
              (doseq [d (.get dependents node)]
                (let [c (dec (long (.get pending d)))]
                  (.put pending d c)
                  (when (zero? c) (become-ready! d)))))
            (become-ready! [node]
              (if (integer? node)
                (vswap! undecided conj node)
                (complete! node)))
            (settle! [time]
              (loop []
                (when-let [serial (first @undecided)]
                  (vswap! undecided disj serial)
                  (let [step (nth steps serial)]
                    (if (state/fresh? @entries @vfs step)
                      (do (vswap! hits inc)
                          (vswap! max-time max time)
                          (vswap! events assoc serial
                                  {:kind :hit :serial serial :start time :end time
                                   :target (:primary step)})
                          (complete! serial))
                      (vswap! ready conj serial))
                    (recur)))))
            (dispatch! [time]
              (while (and (seq @ready) (seq @free))
                (let [serial (first @ready)
                      step (nth steps serial)
                      w (first @free)
                      end (+ time (long (:cost step)))
                      result (try {:ok (commands/execute step @vfs)}
                                  (catch clojure.lang.ExceptionInfo e
                                    (if (err/kiln-error? e) {:error e} (throw e))))]
                  (vswap! ready disj serial)
                  (vswap! free disj w)
                  (vswap! running assoc w {:serial serial :start time :end end :result result})
                  (vswap! max-time max end)
                  (vswap! events assoc serial
                          {:kind :run :serial serial :start time :end end :worker w
                           :target (:primary step) :cmd (:canon step)}))))
            (drop-entry! [serial]
              (vswap! entries dissoc (:primary (nth steps serial))))
            (advance! []
              (let [time (apply min (map :end (vals @running)))
                    finishing (filter (fn [[_ r]] (= time (:end r))) @running)
                    failed (volatile! [])]
                (doseq [[w {:keys [serial result]}] finishing]
                  (vswap! running dissoc w)
                  (vswap! free conj w)
                  (if-let [e (:error result)]
                    (vswap! failed conj [serial e])
                    (let [step (nth steps serial)
                          res (:ok result)]
                      (doseq [[p c] (:outputs res)] (vswap! vfs vfs/write p c))
                      (vswap! entries assoc (:primary step) (state/entry-for step res @vfs))
                      (vswap! ran inc))))
                (if (seq @failed)
                  (let [[_ e] (first (sort-by first @failed))]
                    (vreset! error e)
                    (doseq [[serial _] @failed]
                      (vswap! events assoc-in [serial :kind] :fail)
                      (drop-entry! serial))
                    (doseq [[_ {:keys [serial]}] @running]
                      (vswap! events assoc-in [serial :kind] :cancel)
                      (drop-entry! serial))
                    false)
                  (do (doseq [[_ {:keys [serial]}] finishing] (complete! serial))
                      time))))]
      ;; initialisation: sources and phonies with no dependencies complete at 0
      (doseq [n (sort-by (fn [n] (if (integer? n) [0 n] [1 n])) reachable)]
        (when (zero? (long (.get pending n)))
          (become-ready! n)))
      (loop [time (Long/valueOf 0)]
        (settle! time)
        (dispatch! time)
        (when (seq @running)
          (when-let [t (advance!)]
            (recur t))))
      {:events (vec (sort-by (juxt :start :serial) (vals @events)))
       :ran @ran
       :hits @hits
       :time @max-time
       :error @error
       :vfs @vfs
       :entries @entries})))
