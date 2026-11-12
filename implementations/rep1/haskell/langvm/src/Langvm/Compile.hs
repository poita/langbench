-- | The bytecode compiler: "Langvm.Core" to "Langvm.Bytecode".
module Langvm.Compile
  ( compileProgram
  ) where

import Control.Monad
import Control.Monad.State.Strict
import Data.Array (listArray, (!))
import qualified Data.Array as A
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as Map

import Langvm.Bytecode
import Langvm.Core
import Langvm.SmallArray (emptyA)
import Langvm.Types
import Langvm.Value

data Gen = Gen
  { gCode :: [Instr]
  , gLen :: !Int
  , gDepth :: !Int
  , gMaxDepth :: !Int
  , gLabels :: IM.IntMap Int
  , gNextLabel :: !Int
  , gSlots :: IM.IntMap Int
  , gNextSlot :: !Int
  , gMaxSlot :: !Int
  , gUpvals :: IM.IntMap Int
  , gLoops :: [(Int, Int, Int)]     -- ^ break label, continue label, operand depth
  , gFnTable :: IM.IntMap FnCode
  , gNextFn :: !Int
  }

type G = State Gen

-- | Compile a checked program.
compileProgram :: Globals -> CheckedProgram -> Program
compileProgram g cp = Program fnArr mainIdx implTable
  where
    nFns = A.rangeSize (A.bounds (gFns g))
    methodIdx = Map.fromList (zip (map fst (cpMethods cp)) [nFns ..])
    nM = Map.size methodIdx
    defaultIdx = Map.fromList (zip (map fst (cpDefaults cp)) [nFns + nM ..])
    startFn = nFns + nM + Map.size defaultIdx
    bodies =
      [(fid, f) | (fid, f) <- cpFns cp]
        ++ [(methodIdx Map.! k, f) | (k, f) <- cpMethods cp]
        ++ [(defaultIdx Map.! k, f) | (k, f) <- cpDefaults cp]
    final = execState (forM_ bodies $ \(idx, f) -> do
                          code <- compileFn f
                          modify (\s -> s {gFnTable = IM.insert idx code (gFnTable s)}))
              (Gen [] 0 0 0 IM.empty 0 IM.empty 0 0 IM.empty [] IM.empty startFn)
    dummy = FnCode 0 0 4 (listArray (0, 0) [IPush VUnit])
    total = gNextFn final
    fnArr = listArray (0, total - 1) [IM.findWithDefault dummy i (gFnTable final) | i <- [0 .. total - 1]]
    mainIdx = case Map.lookup "main" (miValues (gMods g ! mainMod)) of
      Just (VIFn f) -> f
      _ -> 0
    mainMod = case [i | (i, m) <- A.assocs (gMods g), miName m == "main", i > 0] of
      (i : _) -> i
      [] -> 1
    implTable = IM.fromList
      [ (implKey (iTrait ii) (iHead ii), listArray (0, length ms - 1) ms)
      | (iid, ii) <- A.assocs (gImpls g)
      , let ti = gTraits g ! iTrait ii
      , let ms = [ case lookup' m (iMethods ii) of
                     Just pos -> Map.findWithDefault 0 (iid, pos) methodIdx
                     Nothing -> Map.findWithDefault 0 (iTrait ii, m) defaultIdx
                 | m <- [0 .. length (tMethods ti) - 1] ]
      ]
    lookup' m xs = fmap snd (lookupBy m xs)
    lookupBy m = foldr (\(a, b) r -> if a == m then Just (a, b) else r) Nothing

-- Emission ---------------------------------------------------------------------------------

effect :: Instr -> Int
effect i = case i of
  IPush _ -> 1
  ILoad _ -> 1
  IStore _ -> -1
  ILoadUp _ -> 1
  IPop -> -1
  IDup -> 1
  IMakeClosure _ n -> 1 - n
  ICall _ n -> 1 - n
  ICallValue n -> negate n
  ICallBuiltin _ n -> 1 - n
  ICallMethod _ _ n -> negate n
  IRet -> -1
  INegI -> 0
  IBitNot -> 0
  INegF -> 0
  INot -> 0
  IJump _ -> 0
  IJumpIfFalse _ -> -1
  IJumpIfTrue _ -> -1
  IMakeList n -> 1 - n
  IMakeMap n -> 1 - 2 * n
  IMakeTuple n -> 1 - n
  IMakeStruct _ n -> 1 - n
  IMakeEnum _ _ n -> 1 - n
  IGetField _ -> 0
  IGetPayload _ -> 0
  IGetTuple _ -> 0
  IIndexGet -> -1
  IIndexSet -> -3
  IIsVariant _ -> 0
  ISeqLen -> 0
  IListRest _ -> 0
  INoMatch -> 0
  _ -> -1   -- binary operators

emit :: Instr -> G ()
emit i = modify $ \s ->
  let d = gDepth s + effect i
  in s { gCode = i : gCode s, gLen = gLen s + 1, gDepth = d, gMaxDepth = max (gMaxDepth s) d }

-- | Emit an instruction without changing the tracked depth (used when unwinding).
emitRaw :: Instr -> G ()
emitRaw i = modify $ \s -> s {gCode = i : gCode s, gLen = gLen s + 1}

setDepth :: Int -> G ()
setDepth d = modify $ \s -> s {gDepth = d, gMaxDepth = max (gMaxDepth s) d}

curDepth :: G Int
curDepth = gets gDepth

newLabel :: G Int
newLabel = do
  s <- get
  put s {gNextLabel = gNextLabel s + 1}
  return (gNextLabel s)

placeLabel :: Int -> G ()
placeLabel l = modify $ \s -> s {gLabels = IM.insert l (gLen s) (gLabels s)}

allocSlot :: G Int
allocSlot = do
  s <- get
  let n = gNextSlot s
  put s {gNextSlot = n + 1, gMaxSlot = max (gMaxSlot s) (n + 1)}
  return n

-- | Bind a variable to a fresh slot.
varSlot :: VarId -> G Int
varSlot v = do
  m <- gets gSlots
  case IM.lookup v m of
    Just sl -> return sl
    Nothing -> do
      sl <- allocSlot
      modify $ \s -> s {gSlots = IM.insert v sl (gSlots s)}
      return sl

withScope :: G a -> G a
withScope act = do
  n <- gets gNextSlot
  r <- act
  modify $ \s -> s {gNextSlot = n}
  return r

-- Functions ---------------------------------------------------------------------------------

compileFn :: CFn -> G FnCode
compileFn (CFn params body) = inFunction params IM.empty (genExpr body)

-- | Compile a function body in a fresh function state.
inFunction :: [VarId] -> IM.IntMap Int -> G () -> G FnCode
inFunction params upvals body = do
  saved <- get
  put saved { gCode = [], gLen = 0, gDepth = 0, gMaxDepth = 0, gLabels = IM.empty
            , gNextLabel = 0, gSlots = IM.fromList (zip params [0 ..]), gNextSlot = length params
            , gMaxSlot = length params, gUpvals = upvals, gLoops = [] }
  body
  emit IRet
  s <- get
  let code = reverse (gCode s)
      resolve i = case i of
        IJump l -> IJump (gLabels s IM.! l)
        IJumpIfFalse l -> IJumpIfFalse (gLabels s IM.! l)
        IJumpIfTrue l -> IJumpIfTrue (gLabels s IM.! l)
        _ -> i
      resolved = map resolve code
      fc = FnCode (length params) (gMaxSlot s) (gMaxSlot s + gMaxDepth s + 4)
                  (listArray (0, length resolved - 1) resolved)
  put s { gCode = gCode saved, gLen = gLen saved, gDepth = gDepth saved, gMaxDepth = gMaxDepth saved
        , gLabels = gLabels saved, gNextLabel = gNextLabel saved, gSlots = gSlots saved
        , gNextSlot = gNextSlot saved, gMaxSlot = gMaxSlot saved, gUpvals = gUpvals saved
        , gLoops = gLoops saved }
  return fc

-- Expressions --------------------------------------------------------------------------------

constValue :: Const -> Value
constValue k = case k of
  KInt n -> VInt n
  KFloat d -> VFloat d
  KStr s -> VStr (strFromString s)
  KChar c -> VChar c
  KBool b -> VBool b
  KUnit -> VUnit

genExprs :: [CExpr] -> G ()
genExprs = mapM_ genExpr

genExpr :: CExpr -> G ()
genExpr ex = case ex of
  CConst k -> emit (IPush (constValue k))
  CVar v -> loadVar v
  CCallFn f args -> genExprs args >> emit (ICall f (length args))
  CCallBuiltin b args -> genExprs args >> emit (ICallBuiltin b (length args))
  CCtor d i [] -> emit (IPush (VEnum d i emptyA))
  CCtor d i args -> genExprs args >> emit (IMakeEnum d i (length args))
  CCallValue f args -> genExpr f >> genExprs args >> emit (ICallValue (length args))
  CCallMethod t m recv args -> genExpr recv >> genExprs args >> emit (ICallMethod t m (length args))
  CUnary op x -> case (op, x) of
    (NegI, CConst (KInt n)) -> emit (IPush (VInt (negate n)))
    _ -> do
      genExpr x
      emit (case op of NegI -> INegI; NegF -> INegF; NotB -> INot; BitNot -> IBitNot)
  CBinary op l r -> do
    genExpr l
    genExpr r
    emit (binInstr op)
  CAnd l r -> do
    lf <- newLabel
    end <- newLabel
    genExpr l
    emit (IJumpIfFalse lf)
    d <- curDepth
    genExpr r
    emit (IJump end)
    setDepth d
    placeLabel lf
    emit (IPush (VBool False))
    placeLabel end
  COr l r -> do
    lt <- newLabel
    end <- newLabel
    genExpr l
    emit (IJumpIfTrue lt)
    d <- curDepth
    genExpr r
    emit (IJump end)
    setDepth d
    placeLabel lt
    emit (IPush (VBool True))
    placeLabel end
  CIndex a i -> genExpr a >> genExpr i >> emit IIndexGet
  CListLit es -> genExprs es >> emit (IMakeList (length es))
  CMapLit kvs -> forM_ kvs (\(k, v) -> genExpr k >> genExpr v) >> emit (IMakeMap (length kvs))
  CTupleLit es -> genExprs es >> emit (IMakeTuple (length es))
  CStructLit d n written
    | map fst written == [0 .. n - 1] -> do
        genExprs (map snd written)
        emit (IMakeStruct d n)
    | otherwise -> withScope $ do
        slots <- forM written $ \(i, e) -> do
          genExpr e
          sl <- allocSlot
          emit (IStore sl)
          return (i, sl)
        forM_ [0 .. n - 1] $ \i -> emit (ILoad (maybe 0 id (lookup i slots)))
        emit (IMakeStruct d n)
  CField e i -> genExpr e >> emit (IGetField i)
  CLambda params body -> genLambda params body
  CIf c a b -> do
    lelse <- newLabel
    end <- newLabel
    genExpr c
    emit (IJumpIfFalse lelse)
    d <- curDepth
    genExpr a
    emit (IJump end)
    setDepth d
    placeLabel lelse
    genExpr b
    placeLabel end
  CMatch scrut arms -> genMatch scrut arms
  CBlock stmts tl -> withScope $ do
    mapM_ genStmt stmts
    maybe (emit (IPush VUnit)) genExpr tl

binInstr :: BinaryOp -> Instr
binInstr op = case op of
  AddI -> IAddI; SubI -> ISubI; MulI -> IMulI; DivI -> IDivI; ModI -> IModI
  AddF -> IAddF; SubF -> ISubF; MulF -> IMulF; DivF -> IDivF
  Concat -> IConcat
  BitAnd -> IBitAnd; BitOr -> IBitOr; BitXor -> IBitXor; Shl -> IShl; Shr -> IShr
  Eq -> IEq; Ne -> INe; Lt -> ILt; Le -> ILe; Gt -> IGt; Ge -> IGe

loadVar :: VarId -> G ()
loadVar v = do
  s <- get
  case IM.lookup v (gSlots s) of
    Just sl -> emit (ILoad sl)
    Nothing -> case IM.lookup v (gUpvals s) of
      Just u -> emit (ILoadUp u)
      Nothing -> error ("langvm: unbound variable " ++ show v)

genLambda :: [VarId] -> CExpr -> G ()
genLambda params body = do
  let free = freeVars params body
  mapM_ loadVar free
  fc <- inFunction params (IM.fromList (zip free [0 ..])) (genExpr body)
  s <- get
  let idx = gNextFn s
  put s {gNextFn = idx + 1, gFnTable = IM.insert idx fc (gFnTable s)}
  emit (IMakeClosure idx (length free))

-- Match ----------------------------------------------------------------------------------------

genMatch :: CExpr -> [CArm] -> G ()
genMatch scrut arms = withScope $ do
  genExpr scrut
  tmp <- allocSlot
  emit (IStore tmp)
  end <- newLabel
  d0 <- curDepth
  forM_ arms $ \(CArm pat guard body) -> do
    next <- newLabel
    withScope $ do
      genPat tmp pat next
      forM_ guard $ \gd -> do
        genExpr gd
        emit (IJumpIfFalse next)
      genExpr body
      emit (IJump end)
    setDepth d0
    placeLabel next
  emit INoMatch
  setDepth (d0 + 1)
  placeLabel end

-- | Test the value in a slot against a pattern, binding variables; jump to
-- the label on failure.  The operand stack is unchanged either way.
genPat :: Int -> CPat -> Int -> G ()
genPat slot pat failL = case pat of
  CPWild -> return ()
  CPVar v -> do
    sl <- varSlot v
    emit (ILoad slot)
    emit (IStore sl)
  CPInt n -> litTest (VInt n)
  CPStr s -> litTest (VStr (strFromString s))
  CPChar c -> litTest (VChar c)
  CPBool b -> litTest (VBool b)
  CPTuple ps -> forM_ (zip [0 ..] ps) $ \(i, p) -> sub (emit (ILoad slot) >> emit (IGetTuple i)) p
  CPVariant i ps -> do
    emit (ILoad slot)
    emit (IIsVariant i)
    emit (IJumpIfFalse failL)
    forM_ (zip [0 ..] ps) $ \(j, p) -> sub (emit (ILoad slot) >> emit (IGetPayload j)) p
  CPStruct fps -> forM_ fps $ \(i, p) -> sub (emit (ILoad slot) >> emit (IGetField i)) p
  CPList ps rest -> do
    let n = length ps
    emit (ILoad slot)
    emit ISeqLen
    emit (IPush (VInt n))
    emit (case rest of Nothing -> IEq; Just _ -> IGe)
    emit (IJumpIfFalse failL)
    forM_ (zip [0 ..] ps) $ \(j, p) ->
      sub (emit (ILoad slot) >> emit (IPush (VInt j)) >> emit IIndexGet) p
    case rest of
      Just (Just r) -> do
        sl <- varSlot r
        emit (ILoad slot)
        emit (IListRest n)
        emit (IStore sl)
      _ -> return ()
  where
    litTest v = do
      emit (ILoad slot)
      emit (IPush v)
      emit IEq
      emit (IJumpIfFalse failL)
    -- Extract a component and match a sub-pattern against it.
    sub push p = case p of
      CPWild -> return ()
      CPVar v -> do
        sl <- varSlot v
        push
        emit (IStore sl)
      _ -> do
        push
        t <- allocSlot
        emit (IStore t)
        genPat t p failL

-- | Bind an irrefutable pattern to the value on top of the stack.
bindTop :: CPat -> G ()
bindTop p = case p of
  CPWild -> emit IPop
  CPVar v -> do
    sl <- varSlot v
    emit (IStore sl)
  _ -> do
    t <- allocSlot
    emit (IStore t)
    fl <- newLabel
    genPat t p fl
    placeLabel fl

-- Statements -----------------------------------------------------------------------------------

genStmt :: CStmt -> G ()
genStmt st = case st of
  CSLet p e -> genExpr e >> bindTop p
  CSVar v e -> do
    genExpr e
    sl <- varSlot v
    emit (IStore sl)
  CSAssign v e -> do
    genExpr e
    m <- gets gSlots
    emit (IStore (m IM.! v))
  CSSetIndex a i e -> genExpr a >> genExpr i >> genExpr e >> emit IIndexSet
  CSExpr e -> genExpr e >> emit IPop
  CSReturn me -> do
    maybe (emit (IPush VUnit)) genExpr me
    emit IRet
  CSWhile c body -> do
    top <- newLabel
    end <- newLabel
    d <- curDepth
    placeLabel top
    genExpr c
    emit (IJumpIfFalse end)
    withLoop end top d (withScope (mapM_ genStmt body))
    emit (IJump top)
    placeLabel end
  CSForList p e body -> withScope $ do
    genExpr e
    sq <- allocSlot
    emit (IStore sq)
    ix <- allocSlot
    emit (IPush (VInt 0))
    emit (IStore ix)
    loopOver p body
      (do emit (ILoad ix); emit (ILoad sq); emit ISeqLen; emit ILt)
      (emit (ILoad sq) >> emit (ILoad ix) >> emit IIndexGet)
      ix
  CSForRange p lo hi body -> withScope $ do
    genExpr lo
    ix <- allocSlot
    emit (IStore ix)
    genExpr hi
    hs <- allocSlot
    emit (IStore hs)
    loopOver p body
      (do emit (ILoad ix); emit (ILoad hs); emit ILt)
      (emit (ILoad ix))
      ix
  CSBreak -> jumpOut fst3
  CSContinue -> jumpOut snd3
  where
    fst3 (a, _, _) = a
    snd3 (_, b, _) = b
    jumpOut pick = do
      loops <- gets gLoops
      d <- curDepth
      case loops of
        (l : _) -> do
          let (_, _, ld) = l
          replicateM_ (d - ld) (emitRaw IPop)
          emitRaw (IJump (pick l))
        [] -> error "langvm: break outside loop"

withLoop :: Int -> Int -> Int -> G a -> G a
withLoop brk cont depth act = do
  modify $ \s -> s {gLoops = (brk, cont, depth) : gLoops s}
  r <- act
  modify $ \s -> s {gLoops = drop 1 (gLoops s)}
  return r

-- | The shared shape of the two @for@ loops.
loopOver :: CPat -> [CStmt] -> G () -> G () -> Int -> G ()
loopOver p body test fetch ix = do
  top <- newLabel
  cont <- newLabel
  end <- newLabel
  d <- curDepth
  placeLabel top
  test
  emit (IJumpIfFalse end)
  withLoop end cont d $ withScope $ do
    fetch
    bindTop p
    mapM_ genStmt body
  placeLabel cont
  emit (ILoad ix)
  emit (IPush (VInt 1))
  emit IAddI
  emit (IStore ix)
  emit (IJump top)
  placeLabel end

-- Free variables --------------------------------------------------------------------------------

-- | The variables used in a lambda body that are bound outside it, in order
-- of first use.
freeVars :: [VarId] -> CExpr -> [VarId]
freeVars params body = go IS.empty [v | v <- used, not (IS.member v bound)]
  where
    (used, boundL) = exprVars body
    bound = IS.fromList (params ++ boundL)
    go _ [] = []
    go seen (v : vs)
      | IS.member v seen = go seen vs
      | otherwise = v : go (IS.insert v seen) vs

-- | Variables used and variables bound, in order of appearance.
exprVars :: CExpr -> ([VarId], [VarId])
exprVars ex = case ex of
  CConst _ -> none
  CVar v -> ([v], [])
  CCallFn _ as -> many as
  CCallBuiltin _ as -> many as
  CCtor _ _ as -> many as
  CCallValue f as -> many (f : as)
  CCallMethod _ _ r as -> many (r : as)
  CUnary _ x -> exprVars x
  CBinary _ l r -> many [l, r]
  CAnd l r -> many [l, r]
  COr l r -> many [l, r]
  CIndex a i -> many [a, i]
  CListLit es -> many es
  CMapLit kvs -> many (concat [[k, v] | (k, v) <- kvs])
  CTupleLit es -> many es
  CStructLit _ _ fs -> many (map snd fs)
  CField e _ -> exprVars e
  CLambda ps b -> let (u, bd) = exprVars b in (u, ps ++ bd)
  CIf c a b -> many [c, a, b]
  CMatch s arms -> comb (exprVars s : [armVars a | a <- arms])
  CBlock ss tl -> comb (map stmtVars ss ++ maybe [] (pure . exprVars) tl)
  where
    none = ([], [])
    many = comb . map exprVars
    armVars (CArm p g b) = comb ([([], patVars p)] ++ maybe [] (pure . exprVars) g ++ [exprVars b])

comb :: [([VarId], [VarId])] -> ([VarId], [VarId])
comb xs = (concatMap fst xs, concatMap snd xs)

stmtVars :: CStmt -> ([VarId], [VarId])
stmtVars st = case st of
  CSLet p e -> comb [exprVars e, ([], patVars p)]
  CSVar v e -> comb [exprVars e, ([], [v])]
  CSAssign v e -> comb [([v], []), exprVars e]
  CSSetIndex a i e -> comb (map exprVars [a, i, e])
  CSExpr e -> exprVars e
  CSReturn me -> maybe ([], []) exprVars me
  CSWhile c b -> comb (exprVars c : map stmtVars b)
  CSForList p e b -> comb (exprVars e : ([], patVars p) : map stmtVars b)
  CSForRange p l h b -> comb (exprVars l : exprVars h : ([], patVars p) : map stmtVars b)
  CSBreak -> ([], [])
  CSContinue -> ([], [])

patVars :: CPat -> [VarId]
patVars p = case p of
  CPVar v -> [v]
  CPTuple ps -> concatMap patVars ps
  CPList ps r -> concatMap patVars ps ++ (case r of Just (Just v) -> [v]; _ -> [])
  CPStruct fs -> concatMap (patVars . snd) fs
  CPVariant _ ps -> concatMap patVars ps
  _ -> []
