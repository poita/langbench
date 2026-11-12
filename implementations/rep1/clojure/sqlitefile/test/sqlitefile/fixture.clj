(ns sqlitefile.fixture
  "Builds small SQLite database files in memory so the tests need no binary
  fixtures and no SQLite library."
  (:require [sqlitefile.bytes :as b]
            [sqlitefile.record :as record])
  (:import (java.io ByteArrayOutputStream)
           (java.nio ByteBuffer)))

(def page-size 512)

(defn- cat-bytes ^bytes [& parts]
  (let [out (ByteArrayOutputStream.)]
    (doseq [p parts] (.write out ^bytes p))
    (.toByteArray out)))

(defn u32 ^bytes [n] (.array (doto (ByteBuffer/allocate 4) (.putInt (int n)))))

(defn table-leaf-cell
  "Table leaf cell with the whole payload local; `overflow` is an optional
  `[local-length first-overflow-page]` pair for a payload that spills."
  ([rowid payload] (cat-bytes (b/encode-varint (alength ^bytes payload))
                              (b/encode-varint rowid) payload))
  ([rowid payload [local pgno]]
   (cat-bytes (b/encode-varint (alength ^bytes payload))
              (b/encode-varint rowid)
              (java.util.Arrays/copyOfRange ^bytes payload 0 (int local))
              (u32 pgno))))

(defn table-interior-cell [child rowid]
  (cat-bytes (u32 child) (b/encode-varint rowid)))

(defn index-leaf-cell [values]
  (let [p (record/encode values)] (cat-bytes (b/encode-varint (alength p)) p)))

(defn index-interior-cell [child values]
  (let [p (record/encode values)]
    (cat-bytes (u32 child) (b/encode-varint (alength p)) p)))

(defn page
  "A B-tree page of `page-size` bytes: `type` byte, `cells` (byte arrays, in
  key order), and `right` child for interior pages. `base` is 100 on page 1."
  [{:keys [type cells right base] :or {base 0}}]
  (let [buf (ByteBuffer/allocate page-size)
        interior? (contains? #{0x02 0x05} type)
        ptr-start (+ base (if interior? 12 8))]
    (loop [cs cells end page-size i 0]
      (if-let [[c & more] (seq cs)]
        (let [start (- end (alength ^bytes c))]
          (.position buf (int start))
          (.put buf ^bytes c)
          (.putShort buf (int (+ ptr-start (* 2 i))) (short start))
          (recur more start (inc i)))
        (do (.put buf (int base) (byte type))
            (.putShort buf (int (+ base 3)) (short (count cells)))
            (.putShort buf (int (+ base 5)) (short end))
            (when interior? (.putInt buf (int (+ base 8)) (int right))))))
    (.array buf)))

(defn overflow-page [next chunk]
  (let [buf (ByteBuffer/allocate page-size)]
    (.putInt buf (int next))
    (.put buf ^bytes chunk)
    (.array buf)))

(defn database
  "Assemble pages (page 1 first, whose first 100 bytes are overwritten with
  the database header) into a database file image."
  ^bytes [pages]
  (let [img (apply cat-bytes pages)
        buf (ByteBuffer/wrap img)]
    (.put buf 0 (.getBytes "SQLite format 3\u0000" "ISO-8859-1"))
    (.putShort buf 16 (short page-size))
    (.put buf 18 (byte 1)) (.put buf 19 (byte 1))
    (.putInt buf 28 (int (count pages)))
    (.putInt buf 56 (int 1))
    img))

(defn schema-row [rowid & values]
  (table-leaf-cell rowid (record/encode (vec values))))

(def big-blob
  "A 1000-byte blob; with 512-byte pages it keeps 39 bytes locally and spills
  961 bytes over two overflow pages (508 + 453)."
  (byte-array (map #(unchecked-byte (* 7 %)) (range 1000))))

(defn sample-db
  "A database with a people table (two-level), an index on people.age with an
  entry on an interior page, a table with an overflow chain, and a view."
  []
  (let [people (fn [rowid & vs] (table-leaf-cell rowid (record/encode (vec vs))))
        blob-record (record/encode [nil big-blob])
        ;; header of that record is 3 bytes; local = 39 bytes of the record
        overflow1 (java.util.Arrays/copyOfRange blob-record 39 (+ 39 508))
        overflow2 (java.util.Arrays/copyOfRange blob-record (+ 39 508) (alength blob-record))]
    (database
     [(page {:type 0x0d :base 100
             :cells [(schema-row 1 "table" "people" "people" 2
                                 "CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT, age INTEGER, score REAL)")
                     (schema-row 2 "index" "people_age" "people" 4 "CREATE INDEX people_age ON people(age)")
                     (schema-row 3 "table" "blobs" "blobs" 7
                                 "CREATE TABLE blobs(id INTEGER PRIMARY KEY, data BLOB)")
                     (schema-row 4 "view" "v" "v" 0 "CREATE VIEW v AS SELECT 1")
                     (schema-row 5 "index" "sqlite_autoindex_blobs_1" "blobs" 3 nil)]})
      ;; 2: people root (interior)
      (page {:type 0x05 :cells [(table-interior-cell 8 2)] :right 9})
      ;; 3: unused
      (byte-array page-size)
      ;; 4: index root (interior) with a real entry (36, rowid 5)
      (page {:type 0x02 :cells [(index-interior-cell 5 [36 5])] :right 6})
      ;; 5, 6: index leaves
      (page {:type 0x0a :cells [(index-leaf-cell [nil 3]) (index-leaf-cell [36 1])]})
      (page {:type 0x0a :cells [(index-leaf-cell [45 2]) (index-leaf-cell [45 4])]})
      ;; 7: blobs leaf with overflow chain 10 -> 11
      (page {:type 0x0d :cells [(table-leaf-cell 1 blob-record [39 10])]})
      ;; 8, 9: people leaves
      (page {:type 0x0d :cells [(people 1 nil "Ada" 36 1) (people 2 nil "Grace" 45 1.7)]})
      (page {:type 0x0d :cells [(people 3 nil "Alan" nil 1.8) (people 4 nil "Bob" 45 nil)
                                (people 5 nil "Cy" 36 2.5)]})
      (overflow-page 11 overflow1)
      (overflow-page 0 overflow2)])))
