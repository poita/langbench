(ns chip8.machine
  "The CHIP-8 machine model: a fixed-size, mutable state container.

  State lives in primitive arrays so that the interpreter in `chip8.cpu` can
  run millions of cycles per second. Scalar registers (PC, I, SP, timers, RNG
  state, key mask, cycle counter) share one `long` array indexed by the
  `reg-*` constants. Use `snapshot` for an immutable, data-oriented view."
  (:require [chip8.font :as font]))

(set! *warn-on-reflection* true)
(set! *unchecked-math* :warn-on-boxed)

(def ^:const memory-size 4096)
(def ^:const rom-address 0x200)
(def ^:const max-rom-size (- memory-size rom-address))
(def ^:const display-width 64)
(def ^:const display-height 32)
(def ^:const rng-seed 0x12345678)

;; Indices into the scalar register array.
(def ^:const reg-pc 0)
(def ^:const reg-i 1)
(def ^:const reg-sp 2)
(def ^:const reg-dt 3)
(def ^:const reg-st 4)
(def ^:const reg-rng 5)
(def ^:const reg-keys 6)
(def ^:const reg-cycles 7)

(deftype Machine [^"[I" mem      ; 4096 entries, each 0..255
                  ^"[I" v       ; V0..VF, each 0..255
                  ^"[I" stack      ; 16 return addresses
                  ^"[I" display    ; 64*32 pixels, row-major, each 0 or 1
                  ^"[J" regs])    ; see reg-* constants

(defn new-machine
  "Creates a machine in its power-on state with `rom` loaded at 0x200.
  `rom` is any sequential collection or byte array of byte values (0-255 or
  signed bytes); at most `max-rom-size` bytes."
  ^Machine [rom]
  (let [rom (vec rom)]
    (when (> (count rom) max-rom-size)
      (throw (ex-info "ROM too large" {:size (count rom) :max max-rom-size})))
    (let [mem (int-array memory-size)
          regs (long-array 8)]
      (doseq [[i b] (map-indexed vector font/font-bytes)]
        (aset mem (+ font/font-address (long i)) (unchecked-int b)))
      (doseq [[i b] (map-indexed vector rom)]
        (aset mem (+ rom-address (long i)) (unchecked-int (bit-and (long b) 0xFF))))
      (aset regs reg-pc rom-address)
      (aset regs reg-rng rng-seed)
      (Machine. mem (int-array 16) (int-array 16)
                (int-array (* display-width display-height)) regs))))

(defn set-keys!
  "Sets the held-key state of `m` from a 16-bit mask (bit k = key k down)."
  [^Machine m ^long mask]
  (aset ^longs (.-regs m) reg-keys (bit-and mask 0xFFFF))
  m)

(defn snapshot
  "Returns an immutable map describing `m`:
  `:pc :i :sp :dt :st :cycles :keys`, `:v` (vector of 16 register values),
  `:stack` (vector of the live stack entries), `:memory` (vector of 4096
  bytes) and `:display` (vector of 32 vectors of 64 0/1 pixels)."
  [^Machine m]
  (let [^longs regs (.-regs m)
        sp (aget regs reg-sp)
        ^ints disp (.-display m)]
    {:pc (aget regs reg-pc)
     :i (aget regs reg-i)
     :sp sp
     :dt (aget regs reg-dt)
     :st (aget regs reg-st)
     :keys (aget regs reg-keys)
     :cycles (aget regs reg-cycles)
     :v (mapv long (.-v m))
     :stack (mapv long (take sp (.-stack m)))
     :memory (mapv long (.-mem m))
     :display (mapv (fn [row]
                      (mapv (fn [col] (long (aget disp (+ (* (long row) display-width) (long col)))))
                            (range display-width)))
                    (range display-height))}))
