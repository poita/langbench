(ns buildsys.scheduler
  "The deterministic parallel-build simulation.

  Ready steps live in sorted sets keyed by serial number, so taking the lowest
  serial is O(log R).  Free workers are a sorted set of worker ids.  Each
  command gets a snapshot of the workspace when it is dispatched (cheap, since
  the workspace is persistent) and runs at its end time."
  (:require [buildsys.errors :as e]
            [buildsys.commands :as commands]
            [buildsys.state :as state]
            [buildsys.vfs :as vfs])
  (:import (clojure.lang ExceptionInfo)))

(defn- run-step
  "Runs `step` against the start-time snapshot `snap`.  Returns
  {:writes [[path content] ...] :in [[path hash] ...] :dep [[path hash] ...]}
  or throws the command's execution error."
  [step snap]
  (let [{:keys [output depfile deps]} (commands/run (:cmd-name step) (:cmd-args step)
                                                    (:file-ins step) snap)]
    {:writes (cond-> [[(:primary step) output]]
               depfile (conj [(:depfile step) depfile]))
     :in (mapv (fn [p] [p (vfs/content-hash snap p)]) (:file-ins step))
     :dep (mapv (fn [p] [p (vfs/content-hash snap p)]) deps)}))

(defn run
  "Simulates the build of the reachable steps.

  `graph` is from `buildsys.graph/build`, `reachable` the reachable node ids,
  `vfs` the workspace and `state` the state map at the start, `jobs` the
  worker count.

  Returns {:events [{:serial :kind (:hit|:run|:fail|:cancel) :start :end :worker} ...]
           :ran n :hits n :time T :error ex-or-nil :vfs vfs :state state}"
  [{:keys [steps succs n-steps] :as graph} reachable vfs0 state0 jobs]
  (let [total (count succs)
        pending (long-array total)
        dependents (reduce (fn [m n]
                             (reduce (fn [m s] (update m s (fnil conj []) n)) m (nth succs n)))
                           {} reachable)
        step-node? (fn [id] (< id n-steps))
        vfs (volatile! vfs0)
        st (volatile! state0)
        undecided (volatile! (sorted-set))
        stale (volatile! (sorted-set))
        free (volatile! (into (sorted-set) (range jobs)))
        running (volatile! (sorted-map))   ; worker -> {:serial :start :end :snap}
        events (volatile! {})              ; serial -> event
        ran (volatile! 0)
        hits (volatile! 0)
        error (volatile! nil)]
    (letfn [(complete! [n]
              (doseq [d (get dependents n)]
                (let [p (dec (aget pending d))]
                  (aset pending d p)
                  (when (zero? p)
                    (if (step-node? d)
                      (vswap! undecided conj d)
                      (complete! d))))))]
      ;; initialisation
      (doseq [n reachable]
        (aset pending n (long (count (nth succs n)))))
      (doseq [n reachable]
        (when (zero? (aget pending n))
          (if (step-node? n) (vswap! undecided conj n) (complete! n))))
      (loop [time 0]
        ;; (A) settle cache hits at the current time
        (loop []
          (when-let [s (first @undecided)]
            (vswap! undecided disj s)
            (let [step (nth steps s)]
              (if (state/stale? (get @st (:primary step)) step @vfs)
                (vswap! stale conj s)
                (do (vswap! hits inc)
                    (vswap! events assoc s {:serial s :kind :hit :start time :end time})
                    (complete! s))))
            (recur)))
        ;; (B) dispatch
        (loop []
          (when (and (seq @stale) (seq @free))
            (let [s (first @stale)
                  w (first @free)
                  step (nth steps s)]
              (vswap! stale disj s)
              (vswap! free disj w)
              (vswap! running assoc w {:serial s :start time :end (+ time (:cost step)) :snap @vfs})
              (vswap! events assoc s {:serial s :kind :run :start time :end (+ time (:cost step)) :worker w})
              (recur))))
        ;; (C) advance the clock
        (when (seq @running)
          (let [t (apply min (map :end (vals @running)))
                finishing (filterv (fn [[_ r]] (= t (:end r))) @running)
                results (mapv (fn [[w r]]
                                (let [step (nth steps (:serial r))]
                                  (vswap! free conj w)
                                  (vswap! running dissoc w)
                                  (try
                                    [(:serial r) (run-step step (:snap r))]
                                    (catch ExceptionInfo ex
                                      (if (e/kiln-error? ex) [(:serial r) ex] (throw ex))))))
                              finishing)
                failed (filterv (fn [[_ r]] (instance? Throwable r)) results)]
            (doseq [[s r] results]
              (when-not (instance? Throwable r)
                (let [step (nth steps s)]
                  (doseq [[p c] (:writes r)] (vswap! vfs vfs/put p c))
                  (vswap! st assoc (:primary step)
                          {:cmd (:cmd-str step)
                           :in (:in r)
                           :dep (:dep r)
                           :out (mapv (fn [[p _]] [p (vfs/content-hash @vfs p)]) (:writes r))})
                  (vswap! ran inc))))
            (if (seq failed)
              (do
                (vreset! error (second (apply min-key first failed)))
                (doseq [[s _] failed]
                  (vswap! events update s assoc :kind :fail)
                  (vswap! st dissoc (:primary (nth steps s))))
                (doseq [[_ r] @running]
                  (vswap! events update (:serial r) assoc :kind :cancel)
                  (vswap! st dissoc (:primary (nth steps (:serial r))))))
              (do (doseq [[s _] results] (complete! s))
                  (recur t)))))))
    (let [evs (vals @events)]
      {:events (vec (sort-by (juxt :start :serial) evs))
       :ran @ran
       :hits @hits
       :time (reduce max 0 (map :end evs))
       :error @error
       :vfs @vfs
       :state @st})))
