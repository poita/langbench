(ns depresolve.search
  "The resolution search of SPEC.md: depth-first, newest version first,
  chronologically backtracking.

  The search runs on an explicit stack of choice points, so recursion depth is
  not a concern. Each step is O(1) apart from the work of pushing the chosen
  version's requirements:

  * `chosen` is an `int[]` (package -> index of the picked version or -1);
  * the pending requirements are an immutable linked list of `Frame`s, each a
    cursor into a version's precompiled requirement array, so a list is shared
    between choice points and never copied;
  * choice points live in parallel arrays used as a stack. Because a package
    is chosen at most once on any path, the stack doubles as the undo trail:
    popping a choice point un-chooses its package.")

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(deftype Frame [^ints reqs ^long pos next])

(defn- push
  "Prepends the requirements `reqs` (an int[] or nil) to the pending list."
  [pending ^ints reqs]
  (if (and reqs (pos? (alength reqs)))
    (Frame. reqs 0 pending)
    pending))

(defn solve
  "Runs the search on a `depresolve.index/Index`. Returns an `int[]` mapping
  each package id to the index (newest first) of its chosen version, or -1 when
  the package was not chosen; returns nil when no resolution exists."
  [{:keys [^objects names ^ints voff ^objects vreqs ^ints root]}]
  (let [n (alength names)
        chosen (int-array n -1)
        cp-pkg (int-array (inc n))
        cp-next (int-array (inc n))
        cp-hi (int-array (inc n))
        cp-rest (object-array (inc n))]
    (loop [pending (push nil root)
           sp 0
           failed false]
      (if failed
        (if (zero? sp)
          nil
          (let [sp (dec sp)
                pkg (aget cp-pkg sp)
                nxt (aget cp-next sp)]
            (if (< nxt (aget cp-hi sp))
              (let [rest (aget cp-rest sp)]
                (aset cp-next sp (unchecked-inc-int nxt))
                (aset chosen pkg nxt)
                (recur (push rest (aget vreqs (+ (aget voff pkg) nxt)))
                       (inc sp)
                       false))
              (do (aset chosen pkg -1)
                  (aset cp-rest sp nil)
                  (recur nil sp true)))))
        (if (nil? pending)
          chosen
          (let [^Frame f pending
                ^ints reqs (.-reqs f)
                pos (.-pos f)
                pkg (aget reqs pos)
                lo (aget reqs (+ pos 1))
                hi (aget reqs (+ pos 2))
                rest (if (< (+ pos 3) (alength reqs))
                       (Frame. reqs (+ pos 3) (.-next f))
                       (.-next f))
                c (aget chosen pkg)]
            (if (>= c 0)
              (if (and (<= lo c) (< c hi))
                (recur rest sp false)
                (recur nil sp true))
              (if (< lo hi)
                (do (aset cp-pkg sp pkg)
                    (aset cp-next sp (unchecked-inc-int lo))
                    (aset cp-hi sp hi)
                    (aset cp-rest sp rest)
                    (aset chosen pkg lo)
                    (recur (push rest (aget vreqs (+ (aget voff pkg) lo)))
                           (inc sp)
                           false))
                (recur nil sp true)))))))))
