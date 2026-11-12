(ns gitrepo.test-util
  "Helpers that build throwaway repositories on disk for the tests."
  (:require [gitrepo.hex :as hex]
            [gitrepo.sha1 :as sha1])
  (:import [java.io ByteArrayOutputStream File]
           [java.nio.file Files]
           [java.nio.file.attribute FileAttribute]
           [java.util.zip Deflater]))

(defn bytes-of ^bytes [^String s] (hex/latin1-bytes s))

(defn deflate
  "zlib-compresses `data` (a byte array) at `level` (0-9) with `strategy`."
  (^bytes [data] (deflate data Deflater/DEFAULT_COMPRESSION Deflater/DEFAULT_STRATEGY))
  (^bytes [^bytes data level strategy]
   (let [d (doto (Deflater. (int level)) (.setStrategy (int strategy)) (.setInput data) .finish)
         out (ByteArrayOutputStream.)
         buf (byte-array 4096)]
     (while (not (.finished d))
       (let [n (.deflate d buf)] (.write out buf 0 n)))
     (.end d)
     (.toByteArray out))))

(defn tmp-dir ^File []
  (.toFile (Files/createTempDirectory "gitrepo-test" (into-array FileAttribute []))))

(defn write-file! [^File f ^bytes data]
  (.mkdirs (.getParentFile f))
  (Files/write (.toPath f) data (into-array java.nio.file.OpenOption [])))

(defn stored-form ^bytes [type ^bytes payload]
  (let [h (bytes-of (str (name type) " " (alength payload) "\u0000"))
        out (byte-array (+ (alength h) (alength payload)))]
    (System/arraycopy h 0 out 0 (alength h))
    (System/arraycopy payload 0 out (alength h) (alength payload))
    out))

(defn object-id [type payload] (sha1/hex-digest (stored-form type payload)))

(defn write-loose!
  "Writes a loose object into `git-dir`, returning its id."
  [^File git-dir type payload]
  (let [payload (if (string? payload) (bytes-of payload) payload)
        id (object-id type payload)]
    (write-file! (File. git-dir (str "objects/" (subs id 0 2) "/" (subs id 2)))
                 (deflate (stored-form type payload)))
    id))

(defn write-ref! [^File git-dir name ^String content]
  (write-file! (File. git-dir ^String name) (bytes-of content)))

(defn tree-payload
  "Payload of a tree from `[mode-string name id-hex]` entries, in order."
  ^bytes [entries]
  (let [out (ByteArrayOutputStream.)]
    (doseq [[mode name id] entries]
      (.write out (bytes-of (str mode " " name "\u0000")))
      (.write out (hex/hex->bytes id)))
    (.toByteArray out)))

(defn commit-payload
  [tree parents {:keys [author committer message]
                 :or {author "A U Thor <a@example.com> 1000 +0000"
                      committer "A U Thor <a@example.com> 1000 +0000"
                      message "msg\n"}}]
  (str "tree " tree "\n"
       (apply str (map #(str "parent " % "\n") parents))
       "author " author "\n"
       "committer " committer "\n\n" message))

;; --------------------------------------------------------------------------
;; packs

(defn- be32 [n] (byte-array (map #(unchecked-byte (bit-shift-right n %)) [24 16 8 0])))

(defn- pack-header [type size]
  (let [out (ByteArrayOutputStream.)
        first-byte (bit-or (bit-shift-left type 4) (bit-and size 15))]
    (loop [rest (bit-shift-right size 4) b first-byte]
      (if (zero? rest)
        (.write out (int b))
        (do (.write out (int (bit-or b 0x80)))
            (recur (bit-shift-right rest 7) (bit-and rest 0x7f)))))
    (.toByteArray out)))

(defn- ofs-encoding [v]
  (let [bs (loop [v v acc (list (bit-and v 0x7f))]
             (let [r (bit-shift-right v 7)]
               (if (zero? r) acc (recur (dec r) (cons (bit-or 0x80 (bit-and (dec r) 0x7f)) acc)))))]
    (byte-array (map unchecked-byte bs))))

(defn write-pack!
  "Writes `<name>.pack` and `<name>.idx` into `git-dir`/objects/pack. `objs`
  is a vector of `{:type kw :payload bytes}` (plain objects) or
  `{:ofs-base i :delta bytes}` / `{:ref-base id :delta bytes}`. Returns the
  ids of plain objects only by position (nil for deltas); pass `:ids` in
  delta entries to give the id the idx should record."
  [^File git-dir ^String name objs]
  (let [pack (ByteArrayOutputStream.)
        _ (do (.write pack (bytes-of "PACK")) (.write pack (be32 2)) (.write pack (be32 (count objs))))
        entries
        (reduce
         (fn [acc o]
           (let [off (.size pack)]
             (cond
               (:ofs-base o)
               (let [base-off (:offset (nth acc (:ofs-base o)))]
                 (.write pack (pack-header 6 (alength ^bytes (:delta o))))
                 (.write pack (ofs-encoding (- off base-off)))
                 (.write pack (deflate (:delta o))))
               (:ref-base o)
               (do (.write pack (pack-header 7 (alength ^bytes (:delta o))))
                   (.write pack (hex/hex->bytes (:ref-base o)))
                   (.write pack (deflate (:delta o))))
               :else
               (do (.write pack (pack-header ({:commit 1 :tree 2 :blob 3 :tag 4} (:type o))
                                             (alength ^bytes (:payload o))))
                   (.write pack (deflate (:payload o)))))
             (conj acc {:offset off :id (or (:id o) (object-id (:type o) (:payload o)))})))
         []
         objs)
        pack-bytes (let [b (.toByteArray pack)]
                     (byte-array (concat b (sha1/digest b))))
        sorted (sort-by :id entries)
        idx (ByteArrayOutputStream.)]
    (.write idx (byte-array (map unchecked-byte [0xff 0x74 0x4f 0x63])))
    (.write idx (be32 2))
    (dotimes [b 256]
      (.write idx (be32 (count (filter #(<= (Integer/parseInt (subs (:id %) 0 2) 16) b) sorted)))))
    (doseq [e sorted] (.write idx (hex/hex->bytes (:id e))))
    (doseq [_ sorted] (.write idx (be32 0)))
    (doseq [e sorted] (.write idx (be32 (:offset e))))
    (.write idx (byte-array 40))
    (write-file! (File. git-dir (str "objects/pack/" name ".pack")) pack-bytes)
    (write-file! (File. git-dir (str "objects/pack/" name ".idx")) (.toByteArray idx))
    (mapv :id entries)))
