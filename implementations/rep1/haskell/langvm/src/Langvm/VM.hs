-- | The stack machine (SPEC.md section 16).
module Langvm.VM
  ( runProgram
  ) where

import Control.Exception (try)
import Control.Monad
import Data.Array (Array, (!))
import Data.Array.Base (getNumElements, unsafeAt, unsafeRead, unsafeWrite)
import Data.Array.IO (IOArray, newArray)
import Data.Bits (unsafeShiftL, unsafeShiftR, complement, (.&.), (.|.), xor)
import Data.IORef
import qualified Data.IntMap.Strict as IM

import Langvm.Bytecode
import Langvm.Collections
import Langvm.SmallArray
import Langvm.Stdlib
import Langvm.Value

-- | The call stack.
data Frames
  = FStop
  | FFrame !(Array Int Instr) !Int !Int !(SmallArray Value) !Int Frames
    -- ^ caller's code, return pc, caller's base, caller's upvalues, result slot

data VM = VM
  { vmStack :: !(IORef (IOArray Int Value))
  , vmSp :: !(IORef Int)
  , vmDepth :: !(IORef Int)
  , vmProg :: Program
  , vmRt :: Runtime
  }

maxFrames :: Int
maxFrames = 20000

-- | Run a program's @main@.  Returns the panic message if it panicked.
runProgram :: Program -> (Str -> IO ()) -> IO (Maybe String)
runProgram prog out = do
  stk <- newArray (0, 65535) VUnit
  stkRef <- newIORef stk
  spRef <- newIORef 0
  depthRef <- newIORef 0
  let vm = VM stkRef spRef depthRef prog rt
      rt = Runtime out (callValue vm)
      mainFn = progFns prog ! progMain prog
  r <- try (exec vm stk (fnCode mainFn) 0 (fnLocals mainFn) 0 emptyA 1 FStop)
  case r of
    Left (Panic m) -> return (Just m)
    Right _ -> return Nothing

-- | Grow the stack so that index @need@ is valid, keeping the first @live@ slots.
ensure :: VM -> IOArray Int Value -> Int -> Int -> IO (IOArray Int Value)
ensure vm stk live need = do
  cap <- getNumElements stk
  if need < cap then return stk else do
    let cap' = max (cap * 2) (need + 1024)
    stk' <- newArray (0, cap' - 1) VUnit
    forM_ [0 .. live - 1] $ \i -> unsafeRead stk i >>= unsafeWrite stk' i
    writeIORef (vmStack vm) stk'
    return stk'

-- | Call a closure from a built-in.
callValue :: VM -> Value -> [Value] -> IO Value
callValue vm f args = case f of
  VClosure fi ups -> do
    sp <- readIORef (vmSp vm)
    depth <- readIORef (vmDepth vm)
    stk <- readIORef (vmStack vm)
    let callee = progFns (vmProg vm) ! fi
        n = length args
    when (depth >= maxFrames) (panic "call stack overflow")
    stk' <- ensure vm stk sp (sp + fnFrame callee + n)
    forM_ (zip [0 ..] args) $ \(i, a) -> unsafeWrite stk' (sp + i) a
    r <- exec vm stk' (fnCode callee) 0 (sp + fnLocals callee) sp ups (depth + 1) FStop
    writeIORef (vmSp vm) sp
    writeIORef (vmDepth vm) depth
    return r
  _ -> error "langvm: call of a non-closure"

fromStack :: IOArray Int Value -> Int -> Int -> IO (SmallArray Value)
fromStack stk from n
  | n == 0 = return emptyA
  | otherwise = do
      m <- newMutA n VUnit
      let go i | i >= n = return ()
               | otherwise = unsafeRead stk (from + i) >>= writeMutA m i >> go (i + 1)
      go 0
      freezeA m

eqValues :: Value -> Value -> IO Bool
eqValues a b = case (a, b) of
  (VInt x, VInt y) -> return (x == y)
  _ -> valueEq a b
{-# INLINE eqValues #-}

-- | The instruction loop.
exec :: VM -> IOArray Int Value -> Array Int Instr -> Int -> Int -> Int
     -> SmallArray Value -> Int -> Frames -> IO Value
exec vm !stk !code !pc !sp !base !upv !depth frames = case unsafeAt code pc of
  IPush v -> unsafeWrite stk sp v >> next (sp + 1)
  ILoad i -> do
    v <- unsafeRead stk (base + i)
    unsafeWrite stk sp v
    next (sp + 1)
  IStore i -> do
    v <- unsafeRead stk (sp - 1)
    unsafeWrite stk (base + i) v
    next (sp - 1)
  ILoadUp i -> unsafeWrite stk sp (indexA upv i) >> next (sp + 1)
  IPop -> next (sp - 1)
  IDup -> do
    v <- unsafeRead stk (sp - 1)
    unsafeWrite stk sp v
    next (sp + 1)
  IMakeClosure f n -> do
    ups <- fromStack stk (sp - n) n
    unsafeWrite stk (sp - n) (VClosure f ups)
    next (sp - n + 1)
  ICall f argc -> do
    let callee = progFns prog ! f
        nb = sp - argc
    when (depth >= maxFrames) (panic "call stack overflow")
    stk' <- ensure vm stk sp (nb + fnFrame callee)
    exec vm stk' (fnCode callee) 0 (nb + fnLocals callee) nb emptyA (depth + 1)
         (FFrame code (pc + 1) base upv nb frames)
  ICallValue argc -> do
    clo <- unsafeRead stk (sp - argc - 1)
    case clo of
      VClosure f ups -> do
        let callee = progFns prog ! f
            nb = sp - argc
        when (depth >= maxFrames) (panic "call stack overflow")
        stk' <- ensure vm stk sp (nb + fnFrame callee)
        exec vm stk' (fnCode callee) 0 (nb + fnLocals callee) nb ups (depth + 1)
             (FFrame code (pc + 1) base upv (nb - 1) frames)
      _ -> error "langvm: call of a non-closure"
  ICallMethod t m argc -> do
    let nb = sp - argc - 1
    recv <- unsafeRead stk nb
    case IM.lookup (implKey t (valueHead recv)) (progImpls prog) of
      Nothing -> error "langvm: no method implementation"
      Just tbl -> do
        let callee = progFns prog ! (tbl ! m)
        when (depth >= maxFrames) (panic "call stack overflow")
        stk' <- ensure vm stk sp (nb + fnFrame callee)
        exec vm stk' (fnCode callee) 0 (nb + fnLocals callee) nb emptyA (depth + 1)
             (FFrame code (pc + 1) base upv nb frames)
  ICallBuiltin b n -> do
    let ab = sp - n
    if isHigherOrder b
      then do
        writeIORef (vmSp vm) sp
        writeIORef (vmDepth vm) depth
        r <- execBuiltin (vmRt vm) b stk ab
        stk' <- readIORef (vmStack vm)
        unsafeWrite stk' ab r
        exec vm stk' code (pc + 1) (ab + 1) base upv depth frames
      else do
        r <- execBuiltin (vmRt vm) b stk ab
        unsafeWrite stk ab r
        next (ab + 1)
  IRet -> do
    r <- unsafeRead stk (sp - 1)
    case frames of
      FStop -> return r
      FFrame code' pc' base' upv' res rest -> do
        unsafeWrite stk res r
        exec vm stk code' pc' (res + 1) base' upv' (depth - 1) rest
  IAddI -> int2 (+)
  ISubI -> int2 (-)
  IMulI -> int2 (*)
  IDivI -> do
    (x, y) <- ints
    when (y == 0) (panic "divide by zero")
    put2 (VInt (if y == -1 then negate x else x `quot` y))
  IModI -> do
    (x, y) <- ints
    when (y == 0) (panic "modulo by zero")
    put2 (VInt (if y == -1 then 0 else x `rem` y))
  INegI -> do
    v <- unsafeRead stk (sp - 1)
    case v of VInt x -> unsafeWrite stk (sp - 1) (VInt (negate x)); _ -> bad
    next sp
  IBitNot -> do
    v <- unsafeRead stk (sp - 1)
    case v of VInt x -> unsafeWrite stk (sp - 1) (VInt (complement x)); _ -> bad
    next sp
  IBitAnd -> int2 (.&.)
  IBitOr -> int2 (.|.)
  IBitXor -> int2 xor
  IShl -> do
    (x, y) <- ints
    when (y < 0 || y > 63) (panic "shift amount out of range")
    put2 (VInt (x `unsafeShiftL` y))
  IShr -> do
    (x, y) <- ints
    when (y < 0 || y > 63) (panic "shift amount out of range")
    put2 (VInt (x `unsafeShiftR` y))
  IAddF -> flt2 (+)
  ISubF -> flt2 (-)
  IMulF -> flt2 (*)
  IDivF -> flt2 (/)
  INegF -> do
    v <- unsafeRead stk (sp - 1)
    case v of VFloat x -> unsafeWrite stk (sp - 1) (VFloat (negate x)); _ -> bad
    next sp
  INot -> do
    v <- unsafeRead stk (sp - 1)
    case v of VBool x -> unsafeWrite stk (sp - 1) (VBool (not x)); _ -> bad
    next sp
  IEq -> do
    (a, b) <- vals
    r <- eqValues a b
    put2 (VBool r)
  INe -> do
    (a, b) <- vals
    r <- eqValues a b
    put2 (VBool (not r))
  ILt -> cmp (\c -> c == CLT)
  ILe -> cmp (\c -> c == CLT || c == CEQ)
  IGt -> cmp (\c -> c == CGT)
  IGe -> cmp (\c -> c == CGT || c == CEQ)
  IConcat -> do
    (a, b) <- vals
    case (a, b) of
      (VStr x, VStr y) -> put2 (VStr (strConcat x y))
      (VList x, VList y) -> do
        xs <- listToList x
        ys <- listToList y
        l <- listFromList (xs ++ ys)
        put2 (VList l)
      _ -> bad
  IJump t -> exec vm stk code t sp base upv depth frames
  IJumpIfFalse t -> do
    v <- unsafeRead stk (sp - 1)
    case v of
      VBool False -> exec vm stk code t (sp - 1) base upv depth frames
      _ -> next (sp - 1)
  IJumpIfTrue t -> do
    v <- unsafeRead stk (sp - 1)
    case v of
      VBool True -> exec vm stk code t (sp - 1) base upv depth frames
      _ -> next (sp - 1)
  IMakeList n -> do
    vs <- mapM (\i -> unsafeRead stk (sp - n + i)) [0 .. n - 1]
    l <- listFromList vs
    unsafeWrite stk (sp - n) (VList l)
    next (sp - n + 1)
  IMakeMap n -> do
    m <- newMap
    forM_ [0 .. n - 1] $ \i -> do
      k <- unsafeRead stk (sp - 2 * n + 2 * i)
      v <- unsafeRead stk (sp - 2 * n + 2 * i + 1)
      mapInsert m k v
    unsafeWrite stk (sp - 2 * n) (VMap m)
    next (sp - 2 * n + 1)
  IMakeTuple n -> do
    arr <- fromStack stk (sp - n) n
    unsafeWrite stk (sp - n) (VTuple arr)
    next (sp - n + 1)
  IMakeStruct d n -> do
    arr <- fromStack stk (sp - n) n
    unsafeWrite stk (sp - n) (VStruct d arr)
    next (sp - n + 1)
  IMakeEnum d v n -> do
    arr <- fromStack stk (sp - n) n
    unsafeWrite stk (sp - n) (VEnum d v arr)
    next (sp - n + 1)
  IGetField i -> do
    v <- unsafeRead stk (sp - 1)
    case v of VStruct _ a -> unsafeWrite stk (sp - 1) (indexA a i); _ -> bad
    next sp
  IGetPayload i -> do
    v <- unsafeRead stk (sp - 1)
    case v of VEnum _ _ a -> unsafeWrite stk (sp - 1) (indexA a i); _ -> bad
    next sp
  IGetTuple i -> do
    v <- unsafeRead stk (sp - 1)
    case v of VTuple a -> unsafeWrite stk (sp - 1) (indexA a i); _ -> bad
    next sp
  IIndexGet -> do
    (c, i) <- vals
    case (c, i) of
      (VList l, VInt ix) -> do
        n <- listLength l
        when (ix < 0 || ix >= n) (panic "index out of bounds")
        listRead l ix >>= put2
      (VStr s, VInt ix) -> do
        when (ix < 0 || ix >= strLength s) (panic "index out of bounds")
        put2 (VChar (strAt s ix))
      (VMap m, k) -> do
        r <- mapLookup m k
        case r of
          Just v -> put2 v
          Nothing -> panic "missing key"
      _ -> bad
  IIndexSet -> do
    c <- unsafeRead stk (sp - 3)
    i <- unsafeRead stk (sp - 2)
    v <- unsafeRead stk (sp - 1)
    case (c, i) of
      (VList l, VInt ix) -> do
        n <- listLength l
        when (ix < 0 || ix >= n) (panic "index out of bounds")
        listWrite l ix v
      (VMap m, k) -> mapInsert m k v
      _ -> bad
    next (sp - 3)
  IIsVariant v -> do
    x <- unsafeRead stk (sp - 1)
    case x of VEnum _ j _ -> unsafeWrite stk (sp - 1) (VBool (j == v)); _ -> bad
    next sp
  ISeqLen -> do
    x <- unsafeRead stk (sp - 1)
    case x of
      VList l -> listLength l >>= unsafeWrite stk (sp - 1) . VInt
      VStr s -> unsafeWrite stk (sp - 1) (VInt (strLength s))
      _ -> bad
    next sp
  IListRest i -> do
    x <- unsafeRead stk (sp - 1)
    case x of
      VList l -> do
        n <- listLength l
        r <- listSlice l i n
        unsafeWrite stk (sp - 1) (VList r)
      _ -> bad
    next sp
  INoMatch -> panic "no match"
  where
    prog = vmProg vm
    next sp' = exec vm stk code (pc + 1) sp' base upv depth frames
    bad :: IO a
    bad = error "langvm: ill-typed instruction"
    vals = do
      a <- unsafeRead stk (sp - 2)
      b <- unsafeRead stk (sp - 1)
      return (a, b)
    ints = do
      a <- unsafeRead stk (sp - 2)
      b <- unsafeRead stk (sp - 1)
      case (a, b) of
        (VInt x, VInt y) -> return (x, y)
        _ -> bad
    put2 v = unsafeWrite stk (sp - 2) v >> next (sp - 1)
    int2 f = do
      (x, y) <- ints
      put2 (VInt (f x y))
    flt2 f = do
      a <- unsafeRead stk (sp - 2)
      b <- unsafeRead stk (sp - 1)
      case (a, b) of
        (VFloat x, VFloat y) -> put2 (VFloat (f x y))
        _ -> bad
    cmp f = do
      (a, b) <- vals
      put2 (VBool (f (compareValues a b)))
