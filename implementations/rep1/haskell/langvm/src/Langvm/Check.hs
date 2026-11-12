-- | The type checker (SPEC.md sections 8 to 12): bidirectional checking with
-- unification, producing the resolved "Langvm.Core" program.
module Langvm.Check
  ( checkProgram
  ) where

import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Array ((!))
import qualified Data.IntMap.Strict as IM
import Data.List (find, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)

import Langvm.Core
import Langvm.Diagnostic
import Langvm.Exhaust
import Langvm.Items
import Langvm.Syntax
import Langvm.Types

-- Monad ---------------------------------------------------------------------------

data Local = Local
  { lVar :: !VarId
  , lTy :: Ty
  , lMut :: !Bool
  , lLevel :: !Int
  }

data RetTy = RetKnown Ty | RetUnknown

data Ctx = Ctx
  { cG :: Globals
  , cMod :: !Int
  , cTParams :: [(String, Ty)]
  , cSelf :: Maybe Ty
  , cSelfVar :: Maybe VarId
  , cLocals :: Map.Map String Local
  , cLevel :: !Int
  , cRet :: RetTy
  , cInLoop :: !Bool
  }

data St = St
  { stTVar :: !Int
  , stVarId :: !Int
  , stSubst :: IM.IntMap Ty
  , stOwners :: [[Int]]
  }

type M = ReaderT Ctx (StateT St (Either Diagnostic))

throwK :: Kind -> Pos -> M a
throwK k p = lift (lift (Left (Diagnostic k p)))

freshVarId :: M VarId
freshVarId = do
  s <- get
  put s {stVarId = stVarId s + 1}
  return (stVarId s)

freshTVar :: M Ty
freshTVar = do
  s <- get
  let v = stTVar s
      owners = case stOwners s of
        (o : os) -> (v : o) : os
        [] -> []
  put s {stTVar = v + 1, stOwners = owners}
  return (TVar v)

-- | Run an action as the owner of any inference variables created during it.
withOwner :: M a -> M (a, [Int])
withOwner act = do
  modify $ \s -> s {stOwners = [] : stOwners s}
  r <- act
  s <- get
  case stOwners s of
    (o : os) -> do
      put s {stOwners = os}
      return (r, o)
    [] -> return (r, [])

shallow :: Ty -> M Ty
shallow t = case t of
  TVar v -> do
    s <- gets stSubst
    case IM.lookup v s of
      Just t' -> shallow t'
      Nothing -> return t
  _ -> return t

zonk :: Ty -> M Ty
zonk t0 = do
  t <- shallow t0
  case t of
    TList a -> TList <$> zonk a
    TMap k v -> TMap <$> zonk k <*> zonk v
    TTuple ts -> TTuple <$> mapM zonk ts
    TFun ps r -> TFun <$> mapM zonk ps <*> zonk r
    TNamed d as -> TNamed d <$> mapM zonk as
    _ -> return t

hasVar :: Ty -> Bool
hasVar t = case t of
  TVar _ -> True
  TList a -> hasVar a
  TMap k v -> hasVar k || hasVar v
  TTuple ts -> any hasVar ts
  TFun ps r -> any hasVar ps || hasVar r
  TNamed _ as -> any hasVar as
  _ -> False

occurs :: Int -> Ty -> Bool
occurs v t = case t of
  TVar w -> v == w
  TList a -> occurs v a
  TMap k x -> occurs v k || occurs v x
  TTuple ts -> any (occurs v) ts
  TFun ps r -> any (occurs v) ps || occurs v r
  TNamed _ as -> any (occurs v) as
  _ -> False

unify :: Ty -> Ty -> M Bool
unify a0 b0 = do
  a <- shallow a0
  b <- shallow b0
  case (a, b) of
    (TVar x, TVar y) | x == y -> return True
    (TVar x, _) -> bind x b
    (_, TVar y) -> bind y a
    (TList x, TList y) -> unify x y
    (TMap k v, TMap k' v') -> unifyAll [k, v] [k', v']
    (TTuple xs, TTuple ys) | length xs == length ys -> unifyAll xs ys
    (TFun ps r, TFun qs s) | length ps == length qs -> unifyAll (ps ++ [r]) (qs ++ [s])
    (TNamed d xs, TNamed e ys) | d == e && length xs == length ys -> unifyAll xs ys
    _ -> return (a == b)
  where
    unifyAll [] _ = return True
    unifyAll _ [] = return True
    unifyAll (x : xs) (y : ys) = do
      ok <- unify x y
      if ok then unifyAll xs ys else return False
    bind v t = do
      t' <- zonk t
      if occurs v t' then return False else do
        modify $ \s -> s {stSubst = IM.insert v t' (stSubst s)}
        return True

mismatchUnless :: Pos -> Ty -> Ty -> M ()
mismatchUnless pos expected actual = do
  ok <- unify expected actual
  unless ok (throwK TypeMismatch pos)

-- Context helpers -------------------------------------------------------------------

globals :: M Globals
globals = asks cG

withBinds :: [(String, VarId, Ty, Bool)] -> M a -> M a
withBinds bs act = do
  lvl <- asks cLevel
  local (\c -> c {cLocals = foldl (\m (n, v, t, mu) -> Map.insert n (Local v t mu lvl) m) (cLocals c) bs}) act

tyScope :: M TyScope
tyScope = do
  c <- ask
  return (TyScope (cMod c) (cTParams c) (cSelf c))

resolveTy :: TypeExpr -> M Ty
resolveTy te = do
  g <- globals
  sc <- tyScope
  either (lift . lift . Left) return (resolveType g sc te)

paramBounds :: Int -> M [Bound]
paramBounds p = do
  g <- globals
  return (maybe [] snd (IM.lookup p (gParams g)))

-- Trait satisfaction (sections 7 and 8.4) ----------------------------------------------

eqHolds :: [Int] -> Ty -> M Bool
eqHolds assume t0 = do
  t <- shallow t0
  g <- globals
  case t of
    TList a -> eqHolds assume a
    TMap _ v -> eqHolds assume v
    TTuple ts -> allM (eqHolds assume) ts
    TFun _ _ -> return False
    TNamed d args
      | d `elem` assume -> return True
      | otherwise -> do
          let di = gDecls g ! d
              sub = IM.fromList (zip (dParams di) args)
              fts = case dKind di of
                KStruct fs -> map (substTy sub . snd) fs
                KEnum vs -> concatMap (map (substTy sub) . snd) vs
          allM (eqHolds (d : assume)) fts
    TParam p -> (\bs -> BEq `elem` bs || BKey `elem` bs) <$> paramBounds p
    _ -> return True

ordHolds :: Ty -> M Bool
ordHolds t0 = do
  t <- shallow t0
  case t of
    TInt -> return True
    TFloat -> return True
    TBool -> return True
    TChar -> return True
    TStr -> return True
    TParam p -> (BOrd `elem`) <$> paramBounds p
    TVar _ -> return True
    _ -> return False

keyHolds :: Ty -> M Bool
keyHolds t0 = do
  t <- shallow t0
  case t of
    TInt -> return True
    TBool -> return True
    TChar -> return True
    TStr -> return True
    TParam p -> (BKey `elem`) <$> paramBounds p
    TVar _ -> return True
    _ -> return False

allM :: Monad m => (a -> m Bool) -> [a] -> m Bool
allM _ [] = return True
allM f (x : xs) = do
  b <- f x
  if b then allM f xs else return False

satisfies :: Ty -> Bound -> M Bool
satisfies t b = case b of
  BEq -> eqHolds [] t
  BOrd -> ordHolds t
  BKey -> keyHolds t
  BTrait tr -> satisfiesTrait t tr

satisfiesTrait :: Ty -> Int -> M Bool
satisfiesTrait t0 tr = do
  t <- zonk t0
  g <- globals
  case t of
    TParam p -> (BTrait tr `elem`) <$> paramBounds p
    TVar _ -> return True
    _ -> case tyHead t of
      Nothing -> return False
      Just h -> case Map.lookup (tr, h) (gImplMap g) of
        Nothing -> return False
        Just ii -> do
          let impl = gImpls g ! ii
              binding = matchHead (iHeadTy impl) t
          allM (\p -> do
                  bs <- paramBounds p
                  case IM.lookup p binding of
                    Nothing -> return True
                    Just ty -> allM (satisfies ty) bs)
               (iParams impl)

-- | Bind the impl's parameters by matching its head against a type.
matchHead :: Ty -> Ty -> IM.IntMap Ty
matchHead pat t = case (pat, t) of
  (TParam p, _) -> IM.singleton p t
  (TList a, TList b) -> matchHead a b
  (TMap a b, TMap c d) -> IM.union (matchHead a c) (matchHead b d)
  (TNamed _ as, TNamed _ bs) -> IM.unions (zipWith matchHead as bs)
  _ -> IM.empty

-- Name resolution ------------------------------------------------------------------------

data ValRes
  = VRLocal Local
  | VRFn Int
  | VRVariant Int Int
  | VRMethod Int Int          -- ^ trait, method index
  | VRType

valueRes :: ValueItem -> ValRes
valueRes (VIFn f) = VRFn f
valueRes (VIVariant d i) = VRVariant d i

valuePub :: Globals -> ValueItem -> Bool
valuePub g (VIFn f) = fPub (gFns g ! f)
valuePub g (VIVariant d _) = dPub (gDecls g ! d)

-- | Resolve a value path.  The flag says whether local bindings are consulted.
resolveValue :: Bool -> Path -> M ValRes
resolveValue useLocals (Path Nothing (Ident n p)) = do
  c <- ask
  let g = cG c
  case (if useLocals then Map.lookup n (cLocals c) else Nothing) of
    Just l -> return (VRLocal l)
    Nothing -> case Map.lookup n (miValues (gMods g ! cMod c)) of
      Just v -> return (valueRes v)
      Nothing -> case Map.lookup n (miValues (gMods g ! 0)) of
        Just v -> return (valueRes v)
        Nothing
          | isTypeName g (cMod c) n -> return VRType
          | otherwise -> throwK UnknownName p
resolveValue _ (Path (Just (Ident a ap)) (Ident b bp)) = do
  c <- ask
  let g = cG c
      m = cMod c
  case Map.lookup a (miImports (gMods g ! m)) of
    Just im -> case Map.lookup b (miValues (gMods g ! im)) of
      Nothing -> throwK UnknownName bp
      Just v -> do
        unless (valuePub g v || im == m) (throwK NotPublic bp)
        return (valueRes v)
    Nothing -> case findVisibleTrait g m a of
      Nothing -> throwK UnknownModule ap
      Just (RBuiltin _) -> throwK UnknownName bp
      Just (RUser t) ->
        case find ((== b) . msName . snd) (zip [0 ..] (tMethods (gTraits g ! t))) of
          Nothing -> throwK UnknownName bp
          Just (i, _) -> return (VRMethod t i)

isTypeName :: Globals -> Int -> String -> Bool
isTypeName g m n =
  n `elem` ["Int", "Float", "Bool", "Char", "Str", "Unit", "Self"]
    || Map.member n (miTypes (gMods g ! m))
    || Map.member n (miTypes (gMods g ! 0))

-- | The trait a qualifier names (rule 2 of section 5.4).
findVisibleTrait :: Globals -> Int -> String -> Maybe TraitRes
findVisibleTrait g m n =
  case Map.lookup n (miTraits (gMods g ! m)) of
    Just t -> Just (RUser t)
    Nothing -> case imported of
      (t : _) -> Just (RUser t)
      [] -> case n of
        "Eq" -> Just (RBuiltin BEq)
        "Ord" -> Just (RBuiltin BOrd)
        "Key" -> Just (RBuiltin BKey)
        _ -> Nothing
  where
    imports = sortOn fst (Map.toList (miImports (gMods g ! m)))
    imported = [ t | (_, im) <- imports, im /= m
               , Just t <- [Map.lookup n (miTraits (gMods g ! im))]
               , tPub (gTraits g ! t) ]

-- | Every trait visible in the module (own and public imported ones).
visibleTraits :: Globals -> Int -> [Int]
visibleTraits g m = dedupe (own ++ imported)
  where
    own = Map.elems (miTraits (gMods g ! m))
    imported = [ t | im <- Map.elems (miImports (gMods g ! m)), im /= m
               , t <- Map.elems (miTraits (gMods g ! im)), tPub (gTraits g ! t) ]
    dedupe = foldr (\x acc -> if x `elem` acc then acc else x : acc) [] . reverse . foldl (flip (:)) []

-- | Resolve a struct/enum name in the types namespace.
resolveTypePath :: Path -> M Int
resolveTypePath (Path Nothing (Ident n p)) = do
  c <- ask
  let g = cG c
  case Map.lookup n (miTypes (gMods g ! cMod c)) of
    Just d -> return d
    Nothing -> case Map.lookup n (miTypes (gMods g ! 0)) of
      Just d -> return d
      Nothing -> throwK UnknownType p
resolveTypePath (Path (Just (Ident a ap)) (Ident b bp)) = do
  c <- ask
  let g = cG c
      m = cMod c
  case Map.lookup a (miImports (gMods g ! m)) of
    Nothing -> throwK UnknownModule ap
    Just im -> case Map.lookup b (miTypes (gMods g ! im)) of
      Nothing -> throwK UnknownType bp
      Just d -> do
        unless (dPub (gDecls g ! d) || im == m) (throwK NotPublic bp)
        return d

pathPos :: Path -> Pos
pathPos (Path (Just q) _) = identPos q
pathPos (Path Nothing n) = identPos n

-- Divergence (section 11.6) -----------------------------------------------------------------

divergesExpr :: Expr -> Bool
divergesExpr e = case exprNode e of
  EIf _ b (Just els) -> divergesBlock b && divergesExpr els
  EMatch _ arms -> not (null arms) && all (divergesExpr . armBody) arms
  EBlock b -> divergesBlock b
  _ -> False

divergesStmt :: Stmt -> Bool
divergesStmt s = case s of
  SReturn {} -> True
  SBreak _ -> True
  SContinue _ -> True
  SLet _ _ _ e -> divergesExpr e
  SVar _ _ _ e -> divergesExpr e
  SAssign _ e -> divergesExpr e
  SExpr e -> divergesExpr e
  SWhile {} -> False
  SFor {} -> False

divergesBlock :: Block -> Bool
divergesBlock b = any divergesStmt (blockStmts b) || maybe False divergesExpr (blockTail b)

-- Generic calls (section 9.4) ---------------------------------------------------------------

data Callee = Callee
  { ceParams :: [Int]
  , ceArgs :: [Ty]
  , ceRet :: Ty
  , ceMk :: [CExpr] -> CExpr
  }

calleeOfFn :: Int -> M Callee
calleeOfFn f = do
  g <- globals
  let fi = gFns g ! f
  return (Callee (fParams fi) (fArgs fi) (fRet fi)
    (case fBuiltin fi of
       Just b -> CCallBuiltin b
       Nothing -> CCallFn f))

calleeOfVariant :: Int -> Int -> M Callee
calleeOfVariant d i = do
  g <- globals
  let di = gDecls g ! d
      payload = case dKind di of
        KEnum vs -> snd (vs !! i)
        KStruct _ -> []
  return (Callee (dParams di) payload (TNamed d (map TParam (dParams di))) (CCtor d i))

-- | The generic-call rule.  The position is the callee's first token.
genericCall :: Pos -> Callee -> [Expr] -> Maybe Ty -> M (Ty, CExpr)
genericCall pos ce args mexp = do
  when (length args /= length (ceArgs ce)) (throwK Arity pos)
  ((ty, cargs, vs), owned) <- withOwner $ do
    vs <- mapM (const freshTVar) (ceParams ce)
    let sigma = IM.fromList (zip (ceParams ce) vs)
    cargs <- zipWithM (\a f -> checkE a (substTy sigma f)) args (ceArgs ce)
    let ret = substTy sigma (ceRet ce)
    case mexp of
      Just t -> mismatchUnless pos t ret
      Nothing -> return ()
    return (ret, cargs, vs)
  forM_ owned $ \v -> do
    t <- zonk (TVar v)
    when (hasVar t) (throwK CannotInfer pos)
  forM_ (zip (ceParams ce) vs) $ \(p, v) -> do
    bs <- paramBounds p
    sol <- zonk v
    forM_ bs $ \b -> do
      ok <- satisfies sol b
      unless ok (throwK UnsatisfiedBound pos)
  ty' <- zonk ty
  return (ty', ceMk ce cargs)

-- Expressions --------------------------------------------------------------------------------

unitC :: CExpr
unitC = CConst KUnit

-- | Check an expression against an expected type.
checkE :: Expr -> Ty -> M CExpr
checkE e@(Expr pos node) t = case node of
  EList es -> do
    mel <- expandWith t (\a -> TList a)
    case mel of
      Just (TList a) -> CListLit <$> mapM (`checkE` a) es
      _ -> throwK TypeMismatch pos
  EMap kvs -> do
    (mt, expanded) <- expandMap t
    case mt of
      Just (TMap k v) -> do
        cs <- forM kvs $ \(ke, ve) -> do
          ck <- checkE ke k
          cv <- checkE ve v
          return (ck, cv)
        when expanded $ do
          k' <- zonk k
          ok <- keyHolds k'
          unless ok (throwK BadKeyType pos)
        return (CMapLit cs)
      _ -> throwK TypeMismatch pos
  ETuple es -> do
    when (length es > 8) (throwK BadArity pos)
    t' <- shallow t
    ts <- case t' of
      TTuple ts | length ts == length es -> return ts
      TVar v -> do
        ts <- mapM (const freshTVar) es
        bindVar v (TTuple ts)
        return ts
      _ -> throwK TypeMismatch pos
    CTupleLit <$> zipWithM checkE es ts
  ELambda lam -> checkLambda lam (Just t)
  EIf c b els -> checkIf pos c b els t
  EMatch s arms -> snd <$> checkMatch pos s arms (Just t)
  EBlock b -> checkBlockAgainst b t
  ECall callee args -> snd <$> checkCall pos callee args (Just t)
  EPath path -> do
    r <- resolveValue True path
    case r of
      VRVariant d i -> do
        ce <- calleeOfVariant d i
        if null (ceArgs ce)
          then snd <$> genericCall pos ce [] (Just t)
          else throwK BadValueRef (identPos (pathName path))
      _ -> defaultCheck
  EStructLit path fields -> snd <$> checkStructLit pos path fields (Just t)
  _ -> defaultCheck
  where
    defaultCheck = do
      (s, c) <- inferE e
      mismatchUnless pos t s
      return c

bindVar :: Int -> Ty -> M ()
bindVar v t = modify $ \s -> s {stSubst = IM.insert v t (stSubst s)}

-- | For a list-like expected type: expand an unsolved variable.
expandWith :: Ty -> (Ty -> Ty) -> M (Maybe Ty)
expandWith t mk = do
  t' <- shallow t
  case t' of
    TList _ -> return (Just t')
    TVar v -> do
      a <- freshTVar
      bindVar v (mk a)
      return (Just (mk a))
    _ -> return Nothing

expandMap :: Ty -> M (Maybe Ty, Bool)
expandMap t = do
  t' <- shallow t
  case t' of
    TMap _ _ -> return (Just t', False)
    TVar v -> do
      k <- freshTVar
      x <- freshTVar
      bindVar v (TMap k x)
      return (Just (TMap k x), True)
    _ -> return (Nothing, False)

-- | Infer an expression's type.
inferE :: Expr -> M (Ty, CExpr)
inferE (Expr pos node) = case node of
  EInt n -> return (TInt, CConst (KInt n))
  EFloat d -> return (TFloat, CConst (KFloat d))
  EStr s -> return (TStr, CConst (KStr s))
  EChar c -> return (TChar, CConst (KChar c))
  EBool b -> return (TBool, CConst (KBool b))
  ESelf -> do
    sv <- asks cSelfVar
    st <- asks cSelf
    case (sv, st) of
      (Just v, Just t) -> return (t, CVar v)
      _ -> throwK SelfOutside pos
  EPath path -> do
    r <- resolveValue True path
    let npos = identPos (pathName path)
    case r of
      VRLocal l -> return (lTy l, CVar (lVar l))
      VRVariant d i -> do
        ce <- calleeOfVariant d i
        if null (ceArgs ce) then genericCall pos ce [] Nothing else throwK BadValueRef npos
      _ -> throwK BadValueRef npos
  EStructLit path fields -> checkStructLit pos path fields Nothing
  ETuple es -> do
    when (length es > 8) (throwK BadArity pos)
    rs <- mapM inferE es
    return (TTuple (map fst rs), CTupleLit (map snd rs))
  EList [] -> throwK CannotInfer pos
  EList (x : xs) -> do
    (t, c) <- inferE x
    cs <- mapM (`checkE` t) xs
    return (TList t, CListLit (c : cs))
  EMap [] -> throwK CannotInfer pos
  EMap ((k, v) : rest) -> do
    (kt, kc) <- inferE k
    ok <- keyHolds kt
    unless ok (throwK BadKeyType (exprPos k))
    (vt, vc) <- inferE v
    cs <- forM rest $ \(k', v') -> do
      ck <- checkE k' kt
      cv <- checkE v' vt
      return (ck, cv)
    return (TMap kt vt, CMapLit ((kc, vc) : cs))
  ELambda lam -> checkLambdaInfer lam
  EIf c b els -> inferIf pos c b els
  EMatch s arms -> checkMatch pos s arms Nothing
  EBlock b -> inferBlock b
  EUnary op x -> case op of
    UNeg -> do
      (t, c) <- inferE x
      t' <- shallow t
      case t' of
        TInt -> return (TInt, CUnary NegI c)
        TFloat -> return (TFloat, CUnary NegF c)
        _ -> throwK TypeMismatch (exprPos x)
    UNot -> do
      c <- checkE x TBool
      return (TBool, CUnary NotB c)
    UBitNot -> do
      c <- checkE x TInt
      return (TInt, CUnary BitNot c)
  EBinary op l r -> inferBinary op l r
  ECall callee args -> checkCall pos callee args Nothing
  EMethod recv m args -> methodCall pos recv m args Nothing
  EIndex a i -> do
    (at, ac) <- inferE a
    at' <- shallow at
    case at' of
      TList t -> do
        ic <- checkE i TInt
        return (t, CIndex ac ic)
      TStr -> do
        ic <- checkE i TInt
        return (TChar, CIndex ac ic)
      TMap k v -> do
        ic <- checkE i k
        return (v, CIndex ac ic)
      _ -> throwK NotIndexable (exprPos a)
  EField x f -> do
    (t, c) <- inferE x
    (idx, ft) <- structField (exprPos x) t f
    return (ft, CField c idx)

-- | Look a field up in a struct type.
structField :: Pos -> Ty -> Ident -> M (Int, Ty)
structField pos t (Ident f fpos) = do
  t' <- zonk t
  g <- globals
  case t' of
    TNamed d args | KStruct fs <- dKind (gDecls g ! d) -> do
      let sub = IM.fromList (zip (dParams (gDecls g ! d)) args)
      case find ((== f) . fst . snd) (zip [0 ..] fs) of
        Nothing -> throwK UnknownField fpos
        Just (i, (_, ft)) -> return (i, substTy sub ft)
    _ -> throwK NotStruct pos

inferBinary :: BinOp -> Expr -> Expr -> M (Ty, CExpr)
inferBinary op l r = case op of
  OpAdd -> arith AddI AddF
  OpSub -> arith SubI SubF
  OpMul -> arith MulI MulF
  OpDiv -> arith DivI DivF
  OpMod -> do
    (lt, lc) <- inferE l
    lt' <- shallow lt
    case lt' of
      TInt -> do
        rc <- checkE r TInt
        return (TInt, CBinary ModI lc rc)
      _ -> throwK TypeMismatch (exprPos l)
  OpConcat -> do
    (lt, lc) <- inferE l
    lt' <- shallow lt
    case lt' of
      TStr -> return ()
      TList _ -> return ()
      _ -> throwK TypeMismatch (exprPos l)
    rc <- checkE r lt'
    return (lt', CBinary Concat lc rc)
  OpBitAnd -> bitwise BitAnd
  OpBitOr -> bitwise BitOr
  OpBitXor -> bitwise BitXor
  OpShl -> bitwise Shl
  OpShr -> bitwise Shr
  OpLt -> cmpOp Lt
  OpLe -> cmpOp Le
  OpGt -> cmpOp Gt
  OpGe -> cmpOp Ge
  OpEq -> eqOp Eq
  OpNe -> eqOp Ne
  OpAnd -> do
    lc <- checkE l TBool
    rc <- checkE r TBool
    return (TBool, CAnd lc rc)
  OpOr -> do
    lc <- checkE l TBool
    rc <- checkE r TBool
    return (TBool, COr lc rc)
  where
    arith iop fop = do
      (lt, lc) <- inferE l
      lt' <- shallow lt
      bop <- case lt' of
        TInt -> return iop
        TFloat -> return fop
        _ -> throwK TypeMismatch (exprPos l)
      rc <- checkE r lt'
      return (lt', CBinary bop lc rc)
    bitwise bop = do
      lc <- checkE l TInt
      rc <- checkE r TInt
      return (TInt, CBinary bop lc rc)
    cmpOp bop = do
      (lt, lc) <- inferE l
      ok <- ordHolds lt
      unless ok (throwK NotOrd (exprPos l))
      rc <- checkE r lt
      return (TBool, CBinary bop lc rc)
    eqOp bop = do
      (lt, lc) <- inferE l
      ok <- eqHolds [] lt
      unless ok (throwK NotEq (exprPos l))
      rc <- checkE r lt
      return (TBool, CBinary bop lc rc)

-- Calls ---------------------------------------------------------------------------------------

finishCall :: Pos -> Maybe Ty -> Ty -> CExpr -> M (Ty, CExpr)
finishCall pos mexp ty c = do
  case mexp of
    Just t -> mismatchUnless pos t ty
    Nothing -> return ()
  return (ty, c)

checkCall :: Pos -> Expr -> [Expr] -> Maybe Ty -> M (Ty, CExpr)
checkCall pos callee args mexp = do
  when (length args > 16) (throwK BadArity pos)
  case exprNode callee of
    EPath path -> do
      r <- resolveValue True path
      case r of
        VRFn f -> do
          ce <- calleeOfFn f
          genericCall pos ce args mexp
        VRVariant d i -> do
          ce <- calleeOfVariant d i
          genericCall pos ce args mexp
        VRMethod t mi -> traitPathCall pos (identPos (pathName path)) t mi args mexp
        VRLocal l -> indirect (lTy l, CVar (lVar l))
        _ -> throwK BadValueRef (identPos (pathName path))
    _ -> inferE callee >>= indirect
  where
    indirect (ft, cf) = do
      ft' <- shallow ft
      case ft' of
        TFun ps r -> do
          when (length ps /= length args) (throwK Arity pos)
          cargs <- zipWithM checkE args ps
          finishCall pos mexp r (CCallValue cf cargs)
        _ -> throwK NotCallable pos

-- | @Tr::m(recv, args...)@.
traitPathCall :: Pos -> Pos -> Int -> Int -> [Expr] -> Maybe Ty -> M (Ty, CExpr)
traitPathCall pos mpos tid midx args mexp = case args of
  [] -> throwK Arity mpos
  (recv : rest) -> do
    (rt, rc) <- inferE recv
    methodCommon pos mpos tid midx rt rc rest mexp

-- | @recv.m(args...)@.
methodCall :: Pos -> Expr -> Ident -> [Expr] -> Maybe Ty -> M (Ty, CExpr)
methodCall pos recv (Ident m mpos) args mexp = do
  when (length args > 16) (throwK BadArity mpos)
  (rt, rc) <- inferE recv
  g <- globals
  md <- asks cMod
  let cands = [ (t, i) | t <- visibleTraits g md
              , Just i <- [fmap fst (find ((== m) . msName . snd) (zip [0 ..] (tMethods (gTraits g ! t))))] ]
  case cands of
    [] -> throwK NoMethod mpos
    [(t, i)] -> methodCommon pos mpos t i rt rc args mexp
    _ -> throwK AmbigMethod mpos

methodCommon :: Pos -> Pos -> Int -> Int -> Ty -> CExpr -> [Expr] -> Maybe Ty -> M (Ty, CExpr)
methodCommon pos mpos tid midx rt rc args mexp = do
  g <- globals
  let ti = gTraits g ! tid
      sig = tMethods ti !! midx
  when (length args /= length (msParams sig)) (throwK Arity mpos)
  r <- zonk rt
  ok <- case r of
    TParam p -> (BTrait tid `elem`) <$> paramBounds p
    _ -> satisfiesTrait r tid
  unless ok (throwK UnsatisfiedBound mpos)
  let sub = IM.singleton (tSelf ti) r
  cargs <- zipWithM (\a t -> checkE a (substTy sub t)) args (msParams sig)
  finishCall pos mexp (substTy sub (msRet sig)) (CCallMethod tid midx rc cargs)

-- Struct literals -------------------------------------------------------------------------------

checkStructLit :: Pos -> Path -> [(Ident, Expr)] -> Maybe Ty -> M (Ty, CExpr)
checkStructLit pos path fields mexp = do
  d <- resolveTypePath path
  g <- globals
  let di = gDecls g ! d
  fdecls <- case dKind di of
    KStruct fs -> return fs
    KEnum _ -> throwK NotStruct pos
  ((ty, cs), owned) <- withOwner $ do
    vs <- mapM (const freshTVar) (dParams di)
    let sty = TNamed d vs
        sub = IM.fromList (zip (dParams di) vs)
    case mexp of
      Just t -> mismatchUnless pos t sty
      Nothing -> return ()
    foldM_ (\seen (Ident f fp, _) -> do
              when (f `elem` seen) (throwK DupField fp)
              unless (f `elem` map fst fdecls) (throwK UnknownField fp)
              return (f : seen)) [] fields
    results <- forM (zip [0 ..] fdecls) $ \(i, (fname, fty)) ->
      case find ((== fname) . identName . fst) fields of
        Nothing -> throwK MissingField pos
        Just (_, fe) -> do
          c <- checkE fe (substTy sub fty)
          return (i :: Int, fname, c)
    let written = [ (i, c) | (Ident f _, _) <- fields
                  , Just (i, _, c) <- [find (\(_, n, _) -> n == f) results] ]
    return (sty, CStructLit d (length fdecls) written)
  forM_ owned $ \v -> do
    t <- zonk (TVar v)
    when (hasVar t) (throwK CannotInfer pos)
  ty' <- zonk ty
  return (ty', cs)

-- Lambdas -----------------------------------------------------------------------------------------

-- | Declare the parameters of a lambda as bindings of the new function level.
lambdaScope :: [(VarId, Ident, Ty)] -> RetTy -> M a -> M a
lambdaScope ps ret act = do
  lvl <- asks cLevel
  let lvl' = lvl + 1
  local (\c -> c { cLevel = lvl', cRet = ret, cInLoop = False
                 , cLocals = foldl (\m (v, Ident n _, t) -> Map.insert n (Local v t False lvl') m) (cLocals c) ps })
    act

checkDupParams :: [Ident] -> M ()
checkDupParams = go []
  where
    go _ [] = return ()
    go seen (Ident n p : r)
      | n `elem` seen = throwK DupName p
      | otherwise = go (n : seen) r

-- | Check a lambda against an expected type.
checkLambda :: Lambda -> Maybe Ty -> M CExpr
checkLambda lam mt = do
  let pos = lamPos lam
      n = length (lamParams lam)
  t <- maybe freshTVar return mt
  t' <- shallow t
  (aps, r) <- case t' of
    TFun aps r | length aps == n -> return (aps, r)
    TVar v -> do
      aps <- mapM (const freshTVar) (lamParams lam)
      r <- freshTVar
      bindVar v (TFun aps r)
      return (aps, r)
    _ -> throwK TypeMismatch pos
  ptys <- forM (zip (lamParams lam) aps) $ \((Ident _ pp, mann), a) ->
    case mann of
      Just te -> do
        ann <- resolveTy te
        ok <- unify a ann
        unless ok (throwK TypeMismatch (tePos te))
        return a
      Nothing -> do
        a' <- shallow a
        case a' of
          TVar _ -> throwK CannotInfer pp
          _ -> return a
  case lamRet lam of
    Just te -> do
      rt <- resolveTy te
      ok <- unify r rt
      unless ok (throwK TypeMismatch (tePos te))
    Nothing -> return ()
  checkDupParams (map fst (lamParams lam))
  vars <- mapM (const freshVarId) (lamParams lam)
  body <- lambdaScope (zip3 vars (map fst (lamParams lam)) ptys) (RetKnown r) $
    checkFnBodyE (lamBody lam) r pos
  return (CLambda vars body)

-- | Synthesise a lambda's type.
checkLambdaInfer :: Lambda -> M (Ty, CExpr)
checkLambdaInfer lam = do
  let pos = lamPos lam
  ptys <- forM (lamParams lam) $ \(Ident _ pp, mann) -> case mann of
    Nothing -> throwK CannotInfer pp
    Just te -> resolveTy te
  mret <- traverse resolveTy (lamRet lam)
  checkDupParams (map fst (lamParams lam))
  vars <- mapM (const freshVarId) (lamParams lam)
  let scope ret = lambdaScope (zip3 vars (map fst (lamParams lam)) ptys) ret
  case mret of
    Just r -> do
      body <- scope (RetKnown r) (checkFnBodyE (lamBody lam) r pos)
      return (TFun ptys r, CLambda vars body)
    Nothing -> do
      (r, body) <- scope RetUnknown (inferE (lamBody lam))
      return (TFun ptys r, CLambda vars body)

-- | A function-like body that is either a block or a plain expression.
checkFnBodyE :: Expr -> Ty -> Pos -> M CExpr
checkFnBodyE e r pos = case exprNode e of
  EBlock b -> checkFnBody b r pos
  _ -> checkE e r

-- Blocks and statements -------------------------------------------------------------------------------

-- | Check statements in order, then run the continuation in the extended scope.
withStmts :: [Stmt] -> M a -> M ([CStmt], a)
withStmts [] k = do
  a <- k
  return ([], a)
withStmts (s : ss) k = case s of
  SLet _ pat mty e -> do
    (t, ce) <- case mty of
      Nothing -> inferE e
      Just te -> do
        a <- resolveTy te
        c <- checkE e a
        return (a, c)
    (pr, binds) <- checkPat pat t []
    unless (prIrr pr) (throwK RefutablePattern (patPos pat))
    (rest, a) <- withBinds [(n, v, bt, False) | (n, v, bt) <- binds] (withStmts ss k)
    return (CSLet (prC pr) ce : rest, a)
  SVar _ (Ident n _) mty e -> do
    (t, ce) <- case mty of
      Nothing -> inferE e
      Just te -> do
        a <- resolveTy te
        c <- checkE e a
        return (a, c)
    v <- freshVarId
    (rest, a) <- withBinds [(n, v, t, True)] (withStmts ss k)
    return (CSVar v ce : rest, a)
  _ -> do
    cs <- checkStmt s
    (rest, a) <- withStmts ss k
    return (cs : rest, a)

checkStmt :: Stmt -> M CStmt
checkStmt s = case s of
  SLet {} -> error "checkStmt: let"
  SVar {} -> error "checkStmt: var"
  SExpr e -> do
    (_, c) <- inferE e
    return (CSExpr c)
  SAssign target rhs -> checkAssign target rhs
  SReturn pos me -> do
    ret <- asks cRet
    case (ret, me) of
      (RetUnknown, _) -> throwK CannotInfer pos
      (RetKnown r, Nothing) -> do
        r' <- shallow r
        unless (r' == TUnit) (throwK TypeMismatch pos)
        return (CSReturn Nothing)
      (RetKnown r, Just e) -> do
        r' <- shallow r
        if r' == TUnit
          then do
            (t, c) <- inferE e
            t' <- shallow t
            unless (t' == TUnit) (throwK TypeMismatch pos)
            return (CSReturn (Just c))
          else CSReturn . Just <$> checkE e r
  SWhile _ c b -> do
    cc <- checkE c TBool
    body <- local (\x -> x {cInLoop = True}) (checkStmtBlock b)
    return (CSWhile cc body)
  SFor _ pat e hi b -> case hi of
    Nothing -> do
      (st, ce) <- inferE e
      st' <- shallow st
      et <- case st' of
        TList t -> return t
        TStr -> return TChar
        _ -> throwK NotIterable (exprPos e)
      (pr, binds) <- checkPat pat et []
      unless (prIrr pr) (throwK RefutablePattern (patPos pat))
      body <- withBinds [(n, v, bt, False) | (n, v, bt) <- binds] $
        local (\x -> x {cInLoop = True}) (checkStmtBlock b)
      return (CSForList (prC pr) ce body)
    Just h -> do
      lo <- checkE e TInt
      hi' <- checkE h TInt
      (pr, binds) <- checkPat pat TInt []
      unless (prIrr pr) (throwK RefutablePattern (patPos pat))
      body <- withBinds [(n, v, bt, False) | (n, v, bt) <- binds] $
        local (\x -> x {cInLoop = True}) (checkStmtBlock b)
      return (CSForRange (prC pr) lo hi' body)
  SBreak pos -> do
    inLoop <- asks cInLoop
    unless inLoop (throwK BreakOutside pos)
    return CSBreak
  SContinue pos -> do
    inLoop <- asks cInLoop
    unless inLoop (throwK BreakOutside pos)
    return CSContinue

checkAssign :: Expr -> Expr -> M CStmt
checkAssign target rhs = case exprNode target of
  EPath (Path Nothing (Ident n p)) -> do
    locals <- asks cLocals
    lvl <- asks cLevel
    case Map.lookup n locals of
      Nothing -> throwK UnknownName p
      Just l -> do
        unless (lMut l) (throwK AssignImmutable p)
        unless (lLevel l == lvl) (throwK AssignCaptured p)
        c <- checkE rhs (lTy l)
        return (CSAssign (lVar l) c)
  EIndex a i -> do
    (at, ac) <- inferE a
    at' <- shallow at
    case at' of
      TList t -> do
        ic <- checkE i TInt
        rc <- checkE rhs t
        return (CSSetIndex ac ic rc)
      TMap k v -> do
        ic <- checkE i k
        rc <- checkE rhs v
        return (CSSetIndex ac ic rc)
      _ -> throwK BadTarget (exprPos a)
  _ -> throwK BadTarget (exprPos target)

-- | The body of a @while@ or @for@: the trailing expression is discarded.
checkStmtBlock :: Block -> M [CStmt]
checkStmtBlock b = do
  (ss, tl) <- withStmts (blockStmts b) $ case blockTail b of
    Nothing -> return []
    Just e -> do
      (_, c) <- inferE e
      return [CSExpr c]
  return (ss ++ tl)

inferBlock :: Block -> M (Ty, CExpr)
inferBlock b = do
  (ss, (t, mc)) <- withStmts (blockStmts b) $ case blockTail b of
    Nothing -> return (TUnit, Nothing)
    Just e -> do
      (t, c) <- inferE e
      return (t, Just c)
  return (t, CBlock ss mc)

-- | A block as an expression checked against a type (section 9.3).
checkBlockAgainst :: Block -> Ty -> M CExpr
checkBlockAgainst b t = do
  (ss, mc) <- withStmts (blockStmts b) $ case blockTail b of
    Just e -> Just <$> checkE e t
    Nothing -> do
      unless (divergesBlock b) $ do
        ok <- unify t TUnit
        unless ok (throwK TypeMismatch (blockPos b))
      return Nothing
  return (CBlock ss mc)

-- | A function, method or lambda body (section 11.6).
checkFnBody :: Block -> Ty -> Pos -> M CExpr
checkFnBody b ret pos = do
  (ss, mc) <- withStmts (blockStmts b) $ case blockTail b of
    Just e -> Just <$> checkE e ret
    Nothing -> do
      unless (divergesBlock b) $ do
        r <- shallow ret
        unless (r == TUnit) (throwK MissingReturn pos)
      return Nothing
  return (CBlock ss mc)

-- if / match -------------------------------------------------------------------------------------------

inferIf :: Pos -> Expr -> Block -> Maybe Expr -> M (Ty, CExpr)
inferIf _ c b1 mels = do
  cc <- checkE c TBool
  case mels of
    Nothing -> do
      cb <- checkBlockAgainst b1 TUnit
      return (TUnit, CIf cc cb unitC)
    Just els
      | not (divergesBlock b1) -> do
          (t, cb) <- inferBlock b1
          ce <- checkE els t
          return (t, CIf cc cb ce)
      | otherwise -> do
          (_, cb) <- inferBlock b1
          (t, ce) <- inferE els
          return (if divergesExpr els then TUnit else t, CIf cc cb ce)

checkIf :: Pos -> Expr -> Block -> Maybe Expr -> Ty -> M CExpr
checkIf pos c b1 mels t = do
  cc <- checkE c TBool
  case mels of
    Nothing -> do
      ok <- unify t TUnit
      unless ok (throwK TypeMismatch pos)
      cb <- checkBlockAgainst b1 t
      return (CIf cc cb unitC)
    Just els -> do
      cb <- checkBlockAgainst b1 t
      ce <- checkE els t
      return (CIf cc cb ce)

checkMatch :: Pos -> Expr -> [Arm] -> Maybe Ty -> M (Ty, CExpr)
checkMatch pos scrut arms mexp = do
  (st, cs) <- inferE scrut
  when (null arms) (throwK NonExhaustive pos)
  (results, acc) <- foldM (\(rs, acc) arm -> do
      (pr, binds) <- checkPat (armPat arm) st []
      let bs = [(n, v, bt, False) | (n, v, bt) <- binds]
      (cg, cb, acc') <- withBinds bs $ do
        cg <- traverse (`checkE` TBool) (armGuard arm)
        (cb, acc') <- case mexp of
          Just t -> do
            cb <- checkE (armBody arm) t
            return (cb, acc)
          Nothing -> case acc of
            Nothing
              | divergesExpr (armBody arm) -> do
                  (_, cb) <- inferE (armBody arm)
                  return (cb, Nothing)
              | otherwise -> do
                  (t, cb) <- inferE (armBody arm)
                  return (cb, Just t)
            Just r -> do
              cb <- checkE (armBody arm) r
              return (cb, acc)
        return (cg, cb, acc')
      return (rs ++ [(arm, pr, CArm (prC pr) cg cb)], acc')) ([], Nothing) arms
  g <- globals
  st' <- zonk st
  let rowsBefore i = [[prU pr] | (j, (a, pr, _)) <- zip [0 :: Int ..] results, j < i, not (isJust (armGuard a))]
  forM_ (zip [0 ..] results) $ \(i, (a, pr, _)) ->
    unless (useful g [st'] (rowsBefore i) [prU pr]) (throwK Unreachable (patPos (armPat a)))
  when (useful g [st'] (rowsBefore (length results)) [UWild]) (throwK NonExhaustive pos)
  let ty = case mexp of
        Just t -> t
        Nothing -> fromMaybe TUnit acc
  return (ty, CMatch cs [c | (_, _, c) <- results])

-- Patterns ---------------------------------------------------------------------------------------------

data PR = PR { prC :: CPat, prU :: UPat, prIrr :: Bool }

type Binds = [(String, VarId, Ty)]

bindName :: Ident -> Ty -> Binds -> M (VarId, Binds)
bindName (Ident n p) t binds = do
  when (any (\(m, _, _) -> m == n) binds) (throwK DupName p)
  v <- freshVarId
  return (v, binds ++ [(n, v, t)])

checkPats :: [(Pattern, Ty)] -> Binds -> M ([PR], Binds)
checkPats [] binds = return ([], binds)
checkPats ((p, t) : rest) binds = do
  (pr, b1) <- checkPat p t binds
  (prs, b2) <- checkPats rest b1
  return (pr : prs, b2)

checkPat :: Pattern -> Ty -> Binds -> M (PR, Binds)
checkPat (Pattern pos node) t0 binds = do
  t <- shallow t0
  g <- globals
  case node of
    PWild -> return (PR CPWild UWild True, binds)
    PFloat -> throwK BadPattern pos
    PInt n -> lit t TInt (CPInt n) (UCInt n)
    PStr s -> lit t TStr (CPStr s) (UCStr s)
    PChar c -> lit t TChar (CPChar c) (UCChar c)
    PBool b -> lit t TBool (CPBool b) (UCBool b)
    PIdent (Path Nothing (Ident n _)) -> do
      c <- ask
      let g' = cG c
          look m = Map.lookup n (miValues (gMods g' ! m))
          found = case look (cMod c) of
            Just v -> Just v
            Nothing -> look 0
          nullary = case found of
            Just (VIVariant d i) | variantArity g' d i == 0 -> Just (d, i)
            _ -> Nothing
      case nullary of
        Just (d, i) -> variantPat t d i []
        Nothing -> do
          (v, b') <- bindName (Ident n pos) t binds
          return (PR (CPVar v) UWild True, b')
    PIdent path -> do
      r <- resolveValue False path
      case r of
        VRVariant d i -> variantPat t d i []
        _ -> throwK TypeMismatch pos
    PVariant path subs -> do
      r <- resolveValue False path
      case r of
        VRVariant d i -> variantPat t d i subs
        VRType -> throwK UnknownName (identPos (pathName path))
        _ -> throwK TypeMismatch pos
    PStruct path fields rest -> do
      d <- resolveTypePath path
      let di = gDecls g ! d
      fdecls <- case dKind di of
        KStruct fs -> return fs
        KEnum _ -> throwK NotStruct (pathPos path)
      args <- case t of
        TNamed d' as | d' == d -> return as
        _ -> throwK TypeMismatch pos
      let sub = IM.fromList (zip (dParams di) args)
      foldM_ (\seen (Ident f fp, _) -> do
                when (f `elem` seen) (throwK DupField fp)
                unless (f `elem` map fst fdecls) (throwK UnknownField fp)
                return (f : seen)) [] fields
      when (not rest && any (\(fname, _) -> fname `notElem` map (identName . fst) fields) fdecls)
        (throwK MissingField pos)
      let step (acc, bs) (fid@(Ident f _), mp) = do
            let (i, fty) = case find ((== f) . fst . snd) (zip [0 :: Int ..] fdecls) of
                  Just (ix, (_, ty)) -> (ix, substTy sub ty)
                  Nothing -> (0, TUnit)
            case mp of
              Just p -> do
                (pr, bs') <- checkPat p fty bs
                return (acc ++ [(i, pr)], bs')
              Nothing -> do
                (v, bs') <- bindName fid fty bs
                return (acc ++ [(i, PR (CPVar v) UWild True)], bs')
      (written, binds') <- foldM step ([], binds) fields
      let ufields = [ maybe UWild (prU . snd) (find ((== i) . fst) written)
                    | i <- [0 .. length fdecls - 1] ]
      return ( PR (CPStruct [(i, prC pr) | (i, pr) <- written])
                  (UCon UCStruct ufields)
                  (all (prIrr . snd) written)
             , binds' )
    PTuple ps -> case t of
      TTuple ts | length ts == length ps -> do
        (prs, b') <- checkPats (zip ps ts) binds
        return (PR (CPTuple (map prC prs)) (UCon (UCTuple (length ps)) (map prU prs)) (all prIrr prs), b')
      _ -> throwK TypeMismatch pos
    PList ps mrest -> case t of
      TList et -> do
        (prs, b1) <- checkPats [(p, et) | p <- ps] binds
        (rv, b2) <- case mrest of
          Just (Just rid) -> do
            (v, b') <- bindName rid (TList et) b1
            return (Just (Just v), b')
          Just Nothing -> return (Just Nothing, b1)
          Nothing -> return (Nothing, b1)
        let u = case mrest of
              Nothing -> UListFix (map prU prs)
              Just _ -> UListOpen (map prU prs)
            irr = isJust mrest && null ps
        return (PR (CPList (map prC prs) rv) u irr, b2)
      _ -> throwK TypeMismatch pos
  where
    lit t expected cp uc =
      if t == expected
        then return (PR cp (UCon uc []) False, binds)
        else throwK TypeMismatch pos
    variantPat t d i subs = do
      g <- globals
      let di = gDecls g ! d
      args <- case t of
        TNamed d' as | d' == d -> return as
        _ -> throwK TypeMismatch pos
      let payload = case dKind di of
            KEnum vs -> snd (vs !! i)
            KStruct _ -> []
          sub = IM.fromList (zip (dParams di) args)
      when (length subs /= length payload) (throwK Arity pos)
      (prs, b') <- checkPats (zip subs (map (substTy sub) payload)) binds
      let single = case dKind di of
            KEnum [_] -> True
            _ -> False
      return ( PR (CPVariant i (map prC prs)) (UCon (UCVariant i) (map prU prs))
                  (single && all prIrr prs)
             , b' )

variantArity :: Globals -> Int -> Int -> Int
variantArity g d i = case dKind (gDecls g ! d) of
  KEnum vs -> length (snd (vs !! i))
  KStruct _ -> 0

-- Program ---------------------------------------------------------------------------------------------------

-- | Pass 4: check every body in module, item and method order.
checkProgram :: Globals -> [[ItemRec]] -> Either Diagnostic CheckedProgram
checkProgram g recs = evalStateT run (St 0 0 IM.empty [])
  where
    items = [(m, r) | (m, rs) <- zip [0 :: Int ..] recs, m > 0, r <- rs]
    run = do
      (f, m, d) <- foldM step ([], [], []) items
      return (CheckedProgram (reverse f) (reverse m) (reverse d))
    step (f, m, d) (mi, r) = do
      (f', m', d') <- runReaderT (item r) (baseCtx mi)
      return (reverse f' ++ f, reverse m' ++ m, reverse d' ++ d)
    baseCtx mi = Ctx g mi [] Nothing Nothing Map.empty 0 RetUnknown False

    -- Check one body.  @selfTy@ is the type of @self@ when there is one.
    runBody tparams selfTy params ret body pos = do
      locals <- foldM (\m (Ident n _, t) -> do
                         v <- freshVarId
                         return (Map.insert n (Local v t False 0) m)) Map.empty params
      let vars = [lVar (locals Map.! identName n) | (n, _) <- params]
      selfV <- case selfTy of
        Nothing -> return Nothing
        Just _ -> Just <$> freshVarId
      let locals' = case (selfV, selfTy) of
            (Just v, Just t) -> Map.insert "self" (Local v t False 0) locals
            _ -> locals
      b <- local (\c -> c { cTParams = tparams, cSelf = selfTy, cSelfVar = selfV
                         , cLocals = locals', cLevel = 0, cRet = RetKnown ret, cInLoop = False })
             (checkFnBody body ret pos)
      return (CFn (maybe [] pure selfV ++ vars) b)

    item r = case r of
      RFn fid fd -> do
        let fi = gFns g ! fid
            tps = zip (map (identName . gpName) (fnGenerics fd)) (map TParam (fParams fi))
        cf <- runBody tps Nothing (zip (map paramName (fnParams fd)) (fArgs fi)) (fRet fi) (fnBody fd) (fnPos fd)
        return ([(fid, cf)], [], [])
      RTrait tid td -> do
        let ti = gTraits g ! tid
            selfT = TParam (tSelf ti)
        ds <- forM (zip [0 :: Int ..] (zip (tdMethods td) (tMethods ti))) $ \(mi, (me, ms)) ->
          case mBody me of
            Nothing -> return []
            Just body -> do
              cf <- runBody [] (Just selfT) (zip (map paramName (mParams me)) (msParams ms))
                      (msRet ms) body (mPos me)
              return [((tid, mi), cf)]
        return ([], [], concat ds)
      RImpl iid idl -> do
        let ii = gImpls g ! iid
            tps = zip (map (identName . gpName) (idGenerics idl)) (map TParam (iParams ii))
            ti = gTraits g ! iTrait ii
            sub = IM.singleton (tSelf ti) (iHeadTy ii)
        ms <- forM (zip [0 :: Int ..] (idMethods idl)) $ \(ix, me) -> do
          let midx = maybe 0 fst (find ((== ix) . snd) (iMethods ii))
              sig = tMethods ti !! midx
          cf <- runBody tps (Just (iHeadTy ii))
                  (zip (map paramName (mParams me)) (map (substTy sub) (msParams sig)))
                  (substTy sub (msRet sig)) (fromMaybe (Block (mPos me) [] Nothing) (mBody me)) (mPos me)
          return ((iid, ix), cf)
        return ([], ms, [])
      _ -> return ([], [], [])
