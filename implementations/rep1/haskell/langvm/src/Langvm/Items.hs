-- | Items, namespaces and type resolution: pass 3 of SPEC.md section 13.2.
module Langvm.Items
  ( ItemRec (..)
  , TraitRes (..)
  , TyScope (..)
  , buildGlobals
  , resolveType
  , resolveTraitRef
  , hasKeyBound
  ) where

import Control.Monad (foldM, forM, forM_, unless, when, zipWithM_)
import Control.Monad.State.Strict
import Data.Array (assocs, listArray, (!))
import qualified Data.IntMap.Strict as IM
import qualified Data.Map.Strict as Map
import Data.List (find)
import Data.Maybe (fromMaybe)

import Langvm.Builtin (builtinFromName)
import Langvm.Diagnostic
import Langvm.Syntax
import Langvm.Types

-- | Where each item of a module went, for the body pass.
data ItemRec
  = RUse
  | RFn Int FnDecl
  | RStruct Int StructDecl
  | REnum Int EnumDecl
  | RTrait Int TraitDecl
  | RImpl Int ImplDecl

-- | The result of resolving a trait reference.
data TraitRes = RBuiltin Bound | RUser Int
  deriving (Eq, Show)

-- | Names in scope while resolving a written type.
data TyScope = TyScope
  { tsMod :: !Int
  , tsParams :: [(String, Ty)]
  , tsSelf :: Maybe Ty
  }

failAt :: Kind -> Pos -> Either Diagnostic a
failAt k p = Left (Diagnostic k p)

reservedNames :: [String]
reservedNames = ["Int", "Float", "Bool", "Char", "Str", "Unit", "Self"]

-- Resolution --------------------------------------------------------------------

-- | Whether @Key@ holds for a type (used for the map key check).
hasKeyBound :: Globals -> Ty -> Bool
hasKeyBound g t = case t of
  TInt -> True
  TBool -> True
  TChar -> True
  TStr -> True
  TParam p -> maybe False (\(_, bs) -> BKey `elem` bs) (IM.lookup p (gParams g))
  TVar _ -> True
  _ -> False

-- | Resolve a written type (section 6.1) in a scope.
resolveType :: Globals -> TyScope -> TypeExpr -> Either Diagnostic Ty
resolveType g sc (TypeExpr pos node) = case node of
  TyList t -> TList <$> go t
  TyMap k v -> do
    k' <- go k
    v' <- go v
    unless (hasKeyBound g k') (failAt BadKeyType pos)
    return (TMap k' v')
  TyTuple ts -> do
    when (length ts > 8) (failAt BadArity pos)
    TTuple <$> mapM go ts
  TyFn ps r -> do
    when (length ps > 16) (failAt BadArity pos)
    ps' <- mapM go ps
    r' <- maybe (return TUnit) go r
    return (TFun ps' r')
  TyPath Nothing (Ident n npos) args -> unqualified n npos args
  TyPath (Just (Ident q qpos)) (Ident n npos) args ->
    case Map.lookup q (miImports (gMods g ! tsMod sc)) of
      Nothing -> failAt UnknownModule qpos
      Just m -> case Map.lookup n (miTypes (gMods g ! m)) of
        Nothing -> failAt UnknownType npos
        Just d -> do
          unless (dPub (gDecls g ! d) || m == tsMod sc) (failAt NotPublic npos)
          named d args
  where
    go = resolveType g sc
    noArgs args t = if null args then Right t else failAt ArityType pos
    named d args = do
      when (length args /= dArity (gDecls g ! d)) (failAt ArityType pos)
      TNamed d <$> mapM go args
    unqualified n npos args
      | Just t <- lookup n (tsParams sc) = noArgs args t
      | n == "Self" = case tsSelf sc of
          Nothing -> failAt SelfOutside pos
          Just t -> noArgs args t
      | Just t <- lookup n prims = noArgs args t
      | Just d <- Map.lookup n (miTypes (gMods g ! tsMod sc)) = named d args
      | Just d <- Map.lookup n (miTypes (gMods g ! 0)) = named d args
      | otherwise = failAt UnknownType npos
    prims = [("Int", TInt), ("Float", TFloat), ("Bool", TBool), ("Char", TChar), ("Str", TStr), ("Unit", TUnit)]

-- | Resolve a trait reference in the traits namespace.
resolveTraitRef :: Globals -> Int -> TraitRef -> Either Diagnostic TraitRes
resolveTraitRef g m (TraitRef q (Ident n npos)) = case q of
  Nothing -> case Map.lookup n (miTraits (gMods g ! m)) of
    Just t -> Right (RUser t)
    Nothing -> case n of
      "Eq" -> Right (RBuiltin BEq)
      "Ord" -> Right (RBuiltin BOrd)
      "Key" -> Right (RBuiltin BKey)
      _ -> failAt UnknownTrait npos
  Just (Ident a apos) -> case Map.lookup a (miImports (gMods g ! m)) of
    Nothing -> failAt UnknownModule apos
    Just im -> case Map.lookup n (miTraits (gMods g ! im)) of
      Nothing -> failAt UnknownTrait npos
      Just t -> do
        unless (tPub (gTraits g ! t) || im == m) (failAt NotPublic npos)
        Right (RUser t)

-- Building ----------------------------------------------------------------------

data Acc = Acc
  { aDecls :: [DeclInfo]
  , aTraits :: [TraitInfo]
  , aFns :: [FnInfo]
  , aImpls :: Int
  , aMods :: [ModInfo]
  }

data ImplRes = ImplRes
  { irTrait :: TraitRes
  , irParams :: [Int]
  , irHeadTy :: Ty
  , irMethods :: [([Ty], Ty)]
  }

-- | Run passes 3.1 to 3.6 over the prelude (first) and the program's modules.
buildGlobals :: [Module] -> Either Diagnostic (Globals, [[ItemRec]])
buildGlobals mods = do
  -- 3.1 declaration
  let step (acc, recs) (mi, m) = do
        (acc', rs) <- declare acc mi m
        return (acc', rs : recs)
  (acc, recsRev) <- foldM step (Acc [] [] [] 0 [], []) (zip [0 ..] mods)
  let recs = reverse recsRev
      modNames = Map.fromList [(modName m, i) | (i, m) <- zip [0 :: Int ..] mods, i > 0]
  -- 3.2 imports
  imports <- forM (zip [0 ..] mods) $ \(mi, m) ->
    if mi == (0 :: Int) then return Map.empty else importsOf modNames m
  let modInfos = [mi {miImports = im} | (mi, im) <- zip (reverse (aMods acc)) imports]
      nDecls = length (aDecls acc)
      nTraits = length (aTraits acc)
      nFns = length (aFns acc)
      g0 = Globals
        { gMods = listArray (0, length modInfos - 1) modInfos
        , gDecls = listArray (0, nDecls - 1) (reverse (aDecls acc))
        , gTraits = listArray (0, nTraits - 1) (reverse (aTraits acc))
        , gFns = listArray (0, nFns - 1) (reverse (aFns acc))
        , gImpls = listArray (0, -1) []
        , gImplMap = Map.empty
        , gParams = IM.empty
        }
  -- 3.3 internal duplicates
  mapM_ (mapM_ internalDups) recs
  -- 3.4 signatures
  (g1, implRes) <- resolveSignatures g0 recs
  -- 3.5 impls
  g2 <- checkImpls g1 recs implRes
  -- 3.6 entry point
  checkMain g2 modNames
  return (g2, recs)

declare :: Acc -> Int -> Module -> Either Diagnostic (Acc, [ItemRec])
declare acc0 mi m = do
  (acc, mInfo, recsRev) <- foldM item (acc0, emptyMod, []) (modItems m)
  return (acc {aMods = mInfo : aMods acc}, reverse recsRev)
  where
    emptyMod = ModInfo (modName m) Map.empty Map.empty Map.empty Map.empty
    reserved (Ident n p) = when (mi /= 0 && n `elem` reservedNames) (failAt ReservedName p)
    item (acc, info, rs) it = case it of
      IUse {} -> return (acc, info, RUse : rs)
      IFn fd -> do
        let Ident n p = fnName fd
            fid = length (aFns acc)
        when (Map.member n (miValues info)) (failAt DupName p)
        let fi = FnInfo n mi (fnPub fd) [] [] TUnit (if mi == 0 then builtinFromName n else Nothing)
        return ( acc {aFns = fi : aFns acc}
               , info {miValues = Map.insert n (VIFn fid) (miValues info)}
               , RFn fid fd : rs )
      IStruct sd -> do
        let nm@(Ident n p) = sdName sd
            did = length (aDecls acc)
        reserved nm
        when (Map.member n (miTypes info)) (failAt DupName p)
        let di = DeclInfo n mi (sdPub sd) (length (sdGenerics sd)) [] (KStruct [])
        return ( acc {aDecls = di : aDecls acc}
               , info {miTypes = Map.insert n did (miTypes info)}
               , RStruct did sd : rs )
      IEnum ed -> do
        let nm@(Ident n p) = edName ed
            did = length (aDecls acc)
        reserved nm
        when (Map.member n (miTypes info)) (failAt DupName p)
        let di = DeclInfo n mi (edPub ed) (length (edGenerics ed)) [] (KEnum [])
            info1 = info {miTypes = Map.insert n did (miTypes info)}
        info2 <- foldM (\inf (idx, v) -> do
                          let Ident vn vp = varName v
                          when (Map.member vn (miValues inf)) (failAt DupName vp)
                          return inf {miValues = Map.insert vn (VIVariant did idx) (miValues inf)})
                       info1 (zip [0 ..] (edVariants ed))
        return (acc {aDecls = di : aDecls acc}, info2, REnum did ed : rs)
      ITrait td -> do
        let nm@(Ident n p) = tdName td
            tid = length (aTraits acc)
        reserved nm
        when (Map.member n (miTraits info)) (failAt DupName p)
        let ti = TraitInfo n mi (tdPub td) 0 []
        return ( acc {aTraits = ti : aTraits acc}
               , info {miTraits = Map.insert n tid (miTraits info)}
               , RTrait tid td : rs )
      IImpl idl -> do
        let iid = aImpls acc
        return (acc {aImpls = iid + 1}, info, RImpl iid idl : rs)

importsOf :: Map.Map String Int -> Module -> Either Diagnostic (Map.Map String Int)
importsOf modNames m = foldM f Map.empty [(p, mn, al) | IUse p mn al <- modItems m]
  where
    f acc (_, Ident mn mp, al) = do
      target <- maybe (failAt UnknownModule mp) Right (Map.lookup mn modNames)
      let Ident bn bp = fromMaybe (Ident mn mp) al
      when (Map.member bn acc) (failAt DupName bp)
      return (Map.insert bn target acc)

-- | The first repeated name, reported at its second occurrence.
dupCheck :: [Ident] -> Either Diagnostic ()
dupCheck = go []
  where
    go _ [] = Right ()
    go seen (Ident n p : r)
      | n `elem` seen = failAt DupName p
      | otherwise = go (n : seen) r

internalDups :: ItemRec -> Either Diagnostic ()
internalDups r = case r of
  RUse -> Right ()
  RFn _ fd -> do
    dupCheck (map gpName (fnGenerics fd))
    dupCheck (map paramName (fnParams fd))
  RStruct _ sd -> do
    dupCheck (map gpName (sdGenerics sd))
    dupCheck (map paramName (sdFields sd))
  REnum _ ed -> dupCheck (map gpName (edGenerics ed))
  RTrait _ td -> methodDups (tdMethods td)
  RImpl _ idl -> do
    dupCheck (map gpName (idGenerics idl))
    methodDups (idMethods idl)
  where
    methodDups ms = do
      dupCheck (map mName ms)
      mapM_ (dupCheck . map paramName . mParams) ms

-- Signatures (3.4) ----------------------------------------------------------------

data S34 = S34
  { sG :: Globals
  , sNext :: !Int
  , sDecls :: IM.IntMap DeclInfo
  , sTraits :: IM.IntMap TraitInfo
  , sFns :: IM.IntMap FnInfo
  , sImplRes :: IM.IntMap ImplRes
  }

type M34 = StateT S34 (Either Diagnostic)

liftE :: Either Diagnostic a -> M34 a
liftE = lift

newParams :: [GenParam] -> M34 [Int]
newParams gps = forM gps $ \gp -> do
  s <- get
  let pid = sNext s
      g = sG s
  put s {sNext = pid + 1, sG = g {gParams = IM.insert pid (identName (gpName gp), []) (gParams g)}}
  return pid

setBounds :: Int -> [Bound] -> M34 ()
setBounds pid bs = modify $ \s ->
  let g = sG s
  in s {sG = g {gParams = IM.adjust (\(n, _) -> (n, bs)) pid (gParams g)}}

-- | Resolve each parameter's bounds in order and record them.
resolveBounds :: Int -> [GenParam] -> [Int] -> M34 ()
resolveBounds m gps pids =
  forM_ (zip gps pids) $ \(gp, pid) -> do
    g <- gets sG
    bs <- forM (gpBounds gp) $ \tr -> liftE $ do
      r <- resolveTraitRef g m tr
      return (case r of RBuiltin b -> b; RUser t -> BTrait t)
    setBounds pid bs

resolveSignatures :: Globals -> [[ItemRec]] -> Either Diagnostic (Globals, IM.IntMap ImplRes)
resolveSignatures g0 recs = do
  s <- execStateT (zipWithM_ (\m rs -> mapM_ (item m) rs) [0 ..] recs)
         (S34 g0 0 IM.empty IM.empty IM.empty IM.empty)
  let g = sG s
      -- Resolved infos replace the stubs of pass 3.1.
      refresh arr resolved =
        let merged = IM.union resolved (IM.fromList (assocs arr))
        in listArray (0, IM.size merged - 1) (IM.elems merged)
  return ( g { gDecls = refresh (gDecls g) (sDecls s)
             , gTraits = refresh (gTraits g) (sTraits s)
             , gFns = refresh (gFns g) (sFns s) }
         , sImplRes s )
  where
    item :: Int -> ItemRec -> M34 ()
    item m r = case r of
      RUse -> return ()
      RFn fid fd -> do
        ps <- newParams (fnGenerics fd)
        resolveBounds m (fnGenerics fd) ps
        g <- gets sG
        let sc = TyScope m (zip (map (identName . gpName) (fnGenerics fd)) (map TParam ps)) Nothing
        args <- liftE (mapM (resolveType g sc . paramType) (fnParams fd))
        ret <- liftE (maybe (Right TUnit) (resolveType g sc) (fnRet fd))
        modify $ \s -> s {sFns = IM.insert fid ((gFns g ! fid) {fParams = ps, fArgs = args, fRet = ret}) (sFns s)}
      RStruct did sd -> do
        ps <- newParams (sdGenerics sd)
        g <- gets sG
        let sc = TyScope m (zip (map (identName . gpName) (sdGenerics sd)) (map TParam ps)) Nothing
        fs <- liftE (forM (sdFields sd) $ \p -> do
                       t <- resolveType g sc (paramType p)
                       return (identName (paramName p), t))
        modify $ \s -> s {sDecls = IM.insert did ((gDecls g ! did) {dParams = ps, dKind = KStruct fs}) (sDecls s)}
      REnum did ed -> do
        ps <- newParams (edGenerics ed)
        g <- gets sG
        let sc = TyScope m (zip (map (identName . gpName) (edGenerics ed)) (map TParam ps)) Nothing
        vs <- liftE (forM (edVariants ed) $ \v -> do
                       ts <- mapM (resolveType g sc) (varPayload v)
                       return (identName (varName v), ts))
        modify $ \s -> s {sDecls = IM.insert did ((gDecls g ! did) {dParams = ps, dKind = KEnum vs}) (sDecls s)}
      RTrait tid td -> do
        s <- get
        let selfId = sNext s
            gp = sG s
        put s {sNext = selfId + 1, sG = gp {gParams = IM.insert selfId ("Self", [BTrait tid]) (gParams gp)}}
        g <- gets sG
        let sc = TyScope m [] (Just (TParam selfId))
        sigs <- liftE (forM (tdMethods td) $ \me -> do
                         args <- mapM (resolveType g sc . paramType) (mParams me)
                         ret <- maybe (Right TUnit) (resolveType g sc) (mRet me)
                         return (MethodSig (identName (mName me)) args ret (maybe False (const True) (mBody me))))
        modify $ \s' -> s' {sTraits = IM.insert tid ((gTraits g ! tid) {tSelf = selfId, tMethods = sigs}) (sTraits s')}
      RImpl iid idl -> do
        ps <- newParams (idGenerics idl)
        resolveBounds m (idGenerics idl) ps
        g <- gets sG
        let names = map (identName . gpName) (idGenerics idl)
            sc0 = TyScope m (zip names (map TParam ps)) (Just (TParam (-1)))
        tr <- liftE (resolveTraitRef g m (idTrait idl))
        headTy <- liftE (resolveType g sc0 (idHead idl))
        let sc = sc0 {tsSelf = Just headTy}
        sigs <- liftE (forM (idMethods idl) $ \me -> do
                         args <- mapM (resolveType g sc . paramType) (mParams me)
                         ret <- maybe (Right TUnit) (resolveType g sc) (mRet me)
                         return (args, ret))
        modify $ \s -> s {sImplRes = IM.insert iid (ImplRes tr ps headTy sigs) (sImplRes s)}

-- Impls (3.5) ---------------------------------------------------------------------

checkImpls :: Globals -> [[ItemRec]] -> IM.IntMap ImplRes -> Either Diagnostic Globals
checkImpls g recs resMap = do
  (infos, implMap) <- foldM step ([], Map.empty) [(iid, idl) | rs <- recs, RImpl iid idl <- rs]
  let infos' = reverse infos
  return g { gImpls = listArray (0, length infos' - 1) infos', gImplMap = implMap }
  where
    step (acc, implMap) (iid, idl) = do
      let ir = resMap IM.! iid
          m = modOfImpl iid
          pos = idPos idl
          headTy = irHeadTy ir
      tid <- case irTrait ir of
        RBuiltin _ -> failAt BuiltinTraitImpl pos
        RUser t -> Right t
      unless (validHead (irParams ir) headTy) (failAt BadImplHead (tePos (idHead idl)))
      let used = tyParamsOf headTy
      forM_ (zip (idGenerics idl) (irParams ir)) $ \(gp, pid) ->
        unless (pid `elem` used) (failAt UnusedParam (identPos (gpName gp)))
      let hc = fromMaybe 0 (tyHead headTy)
      when (Map.member (tid, hc) implMap) (failAt DupImpl pos)
      let ti = gTraits g ! tid
          defined = map (identName . mName) (idMethods idl)
      forM_ (tMethods ti) $ \ms ->
        when (not (msDefault ms) && msName ms `notElem` defined) (failAt MissingMethod pos)
      forM_ (zip (idMethods idl) (irMethods ir)) $ \(me, (args, ret)) -> do
        let Ident n npos = mName me
        case find ((== n) . msName . snd) (zip [0 :: Int ..] (tMethods ti)) of
          Nothing -> failAt ExtraMethod npos
          Just (_, ms) -> do
            let sub = IM.singleton (tSelf ti) headTy
                okArgs = map (substTy sub) (msParams ms) == args
                okRet = substTy sub (msRet ms) == ret
            unless (okArgs && okRet) (failAt SigMismatch npos)
      let methodMap = [ (ix, pos') | (pos', me) <- zip [0 ..] (idMethods idl)
                      , Just (ix, _) <- [find ((== identName (mName me)) . msName . snd) (zip [0 ..] (tMethods ti))] ]
          info = ImplInfo tid hc (irParams ir) headTy m methodMap
      return (info : acc, Map.insert (tid, hc) iid implMap)
    modOfImpl iid = case [m | (m, rs) <- zip [0 ..] recs, RImpl i _ <- rs, i == iid] of
      (m : _) -> m
      [] -> 0
    validHead params t = case t of
      TList (TParam p) -> p `elem` params
      TMap (TParam p) (TParam q) -> p `elem` params && q `elem` params && p /= q
      TNamed _ as -> all isParam as && distinct as
      _ -> maybe False (const True) (headPrim t)
      where
        isParam (TParam p) = p `elem` params
        isParam _ = False
        distinct as = length as == length (Map.fromList [(p, ()) | TParam p <- as])

-- Entry point (3.6) -----------------------------------------------------------------

checkMain :: Globals -> Map.Map String Int -> Either Diagnostic ()
checkMain g modNames = do
  let bad = failAt NoMain (Pos 1 1)
  mi <- maybe bad Right (Map.lookup "main" modNames)
  case Map.lookup "main" (miValues (gMods g ! mi)) of
    Just (VIFn f) -> do
      let fi = gFns g ! f
      unless (null (fParams fi) && null (fArgs fi) && fRet fi == TUnit) bad
    _ -> bad
