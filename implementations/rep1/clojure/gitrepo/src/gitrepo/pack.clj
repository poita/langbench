(ns gitrepo.pack
  "Pack index (version 2) lookups and packfile object headers."
  (:require [gitrepo.error :as err]
            [gitrepo.hex :as hex])
  (:import [java.nio.file Files]
           [java.io File]))

(set! *warn-on-reflection* true)

(defn- u8 ^long [^bytes b ^long i] (bit-and 0xff (aget b i)))

(defn- be32 ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (u8 b i) 24) (bit-shift-left (u8 b (+ i 1)) 16)
          (bit-shift-left (u8 b (+ i 2)) 8) (u8 b (+ i 3))))

(defn- be64 ^long [^bytes b ^long i]
  (bit-or (bit-shift-left (be32 b i) 32) (be32 b (+ i 4))))

(def ^:private ^:const ids-start 1032)

(defn open-pack
  "Loads the pack `name` from `.idx` file `idx-file` and `.pack` file
  `pack-file`. Returns a pack map `{:name :idx :pack :count}`, or nil when
  either file is not a version-2 index / pack."
  [^String name ^File idx-file ^File pack-file]
  (let [idx (Files/readAllBytes (.toPath idx-file))
        pack (Files/readAllBytes (.toPath pack-file))]
    (when (and (>= (alength idx) (+ ids-start 40))
               (= 0xff744f63 (be32 idx 0))
               (= 2 (be32 idx 4))
               (>= (alength pack) 32)
               (= 0x5041434b (be32 pack 0))
               (= 2 (be32 pack 4)))
      (let [n (be32 idx (+ 8 (* 4 255)))]
        (when (>= (alength idx) (+ ids-start (* 28 n) 40))
          {:name name :idx idx :pack pack :count n})))))

(defn- fanout ^long [^bytes idx ^long b]
  (be32 idx (+ 8 (* 4 b))))

(defn- compare-id
  "Compares the id at table position `i` with the 20 bytes `target`."
  ^long [^bytes idx ^long i ^bytes target]
  (let [base (+ ids-start (* 20 i))]
    (loop [k 0]
      (if (= k 20)
        0
        (let [d (- (u8 idx (+ base k)) (bit-and 0xff (aget target k)))]
          (if (zero? d) (recur (inc k)) d))))))

(defn- bucket
  "[lo hi) positions of ids whose first byte is `b`."
  [^bytes idx ^long b]
  [(if (zero? b) 0 (fanout idx (dec b))) (fanout idx b)])

(defn- lower-bound
  "The first position in [lo, hi) whose id is >= target (or hi)."
  ^long [^bytes idx ^long lo ^long hi ^bytes target]
  (loop [lo lo hi hi]
    (if (< lo hi)
      (let [mid (quot (+ lo hi) 2)]
        (if (neg? (compare-id idx mid target))
          (recur (inc mid) hi)
          (recur lo mid)))
      lo)))

(defn find-position
  "The position of the 20-byte id `id20` in the pack's sorted id table, or -1."
  ^long [pack ^bytes id20]
  (let [^bytes idx (:idx pack)
        [lo hi] (bucket idx (bit-and 0xff (aget id20 0)))
        p (lower-bound idx lo hi id20)]
    (if (and (< p hi) (zero? (compare-id idx p id20))) p -1)))

(defn id-at
  "The hex id at table position `i`."
  ^String [pack ^long i]
  (hex/bytes->hex ^bytes (:idx pack) (+ ids-start (* 20 i)) 20))

(defn offset-at
  "The offset in the packfile of the object at table position `i`."
  ^long [pack ^long i]
  (let [^bytes idx (:idx pack)
        n (long (:count pack))
        v (be32 idx (+ ids-start (* 24 n) (* 4 i)))]
    (if (zero? (bit-and v 0x80000000))
      v
      (let [j (bit-and v 0x7fffffff)
            at (+ ids-start (* 28 n) (* 8 j))]
        (when (> (+ at 8 40) (alength idx)) (err/fail :damaged "pack index: bad 64-bit offset"))
        (be64 idx at)))))

(defn prefix-matches
  "Up to `limit` hex ids of the pack that start with the lowercase hex
  `prefix` (4 to 40 digits), in ascending order."
  [pack ^String prefix ^long limit]
  (let [^bytes idx (:idx pack)
        lowest (hex/hex->bytes (str prefix (apply str (repeat (- 40 (.length prefix)) "0"))))
        [lo hi] (bucket idx (bit-and 0xff (aget lowest 0)))
        start (lower-bound idx lo hi lowest)]
    (loop [i start acc []]
      (if (or (>= i hi) (>= (count acc) limit))
        acc
        (let [^String id (id-at pack i)]
          (if (.startsWith id prefix)
            (recur (inc i) (conj acc id))
            acc))))))

(defn read-header
  "Parses the object header at `offset` of the pack. Returns
  `{:type <1-4, 6, 7> :size n :data-offset p}` plus `:base-offset` for type 6
  or `:base-id` (hex) for type 7."
  [pack ^long offset]
  (let [^bytes b (:pack pack)
        len (alength b)
        _ (when (or (< offset 12) (>= offset (- len 20))) (err/fail :damaged "pack: bad offset"))
        c (u8 b offset)
        type (bit-and 7 (bit-shift-right c 4))
        [size p] (loop [p (inc offset) c c shift 4 size (bit-and c 15)]
                   (if (zero? (bit-and c 0x80))
                     [size p]
                     (do (when (>= p len) (err/fail :damaged "pack: truncated header"))
                         (let [c (u8 b p)]
                           (recur (inc p) c (+ shift 7)
                                  (bit-or size (bit-shift-left (bit-and c 0x7f) shift)))))))
        p (long p)]
    (case (long type)
      (1 2 3 4) {:type type :size size :data-offset p}
      6 (let [[v q] (loop [p p c (u8 b p) v (bit-and c 0x7f)]
                      (if (zero? (bit-and c 0x80))
                        [v (inc p)]
                        (do (when (>= (inc p) len) (err/fail :damaged "pack: truncated header"))
                            (let [c (u8 b (inc p))]
                              (recur (inc p) c (bit-or (bit-shift-left (inc v) 7) (bit-and c 0x7f)))))))]
          (when (or (<= v 0) (> v offset)) (err/fail :damaged "pack: bad delta base offset"))
          {:type 6 :size size :data-offset q :base-offset (- offset v)})
      7 (do (when (> (+ p 20) len) (err/fail :damaged "pack: truncated header"))
            {:type 7 :size size :data-offset (+ p 20) :base-id (hex/bytes->hex b p 20)})
      (err/fail :damaged "pack: invalid object type"))))
