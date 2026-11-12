-- |
-- Module      : Spiremark.Card.Parse
-- Description : Reader and validator for card databases.
--
-- Turns the text of a database into a 'CardDb', enforcing every rule of
-- SPEC.md section 5.2 and 5.4.  Any violation yields 'Nothing' (the CLI reports
-- it as @FATAL bad-database@).
module Spiremark.Card.Parse
  ( parseDatabase
  , loadDatabase
  ) where

import Control.Exception (SomeException, evaluate, try)
import Control.Monad (foldM, forM, unless, when)
import Data.Char (isAsciiUpper, isDigit)
import qualified Data.Map.Strict as M
import Data.Maybe (isJust)
import System.IO

import Spiremark.Card.Types
import Spiremark.SExpr

-- | Read and validate a database file.  Unreadable files (missing, bad UTF-8)
-- are invalid like any other.
loadDatabase :: FilePath -> IO (Maybe CardDb)
loadDatabase path = do
  r <- try (withFile path ReadMode $ \h -> do
    hSetEncoding h utf8
    s <- hGetContents h
    _ <- evaluate (length s)
    return s)
  return $ case r of
    Left e -> const Nothing (e :: SomeException)
    Right s -> parseDatabase s

-- | Validate database text.
parseDatabase :: String -> Maybe CardDb
parseDatabase src = do
  exprs <- parseSExprs src
  cards <- mapM parseCard exprs
  db <- foldM ins M.empty cards
  mapM_ (checkRefs db) (M.elems db)
  return db
  where
    ins m c
      | M.member (cardId c) m = Nothing
      | otherwise = Just (M.insert (cardId c) c m)

-- | Every summoned / conjured card must exist; summoned cards may not be rites.
checkRefs :: CardDb -> Card -> Maybe ()
checkRefs db c = mapM_ check (concatMap abilityRefs (cardAbilities c))
  where
    check (isSummon, cid) = case M.lookup cid db of
      Nothing -> Nothing
      Just t -> when (isSummon && cardType t == Rite) Nothing
    abilityRefs ab = concatMap effRefs (abEffects ab)
    effRefs e = case e of
      ESummon cid _ _ -> [(True, cid)]
      EConjure cid _ _ -> [(False, cid)]
      EDelay _ es -> concatMap effRefs es
      EIf _ a b -> concatMap effRefs (a ++ b)
      EEach _ es -> concatMap effRefs es
      ERepeat _ es -> concatMap effRefs es
      _ -> []

-- ---------------------------------------------------------------------------
-- Cards

data Clauses = Clauses
  { clName :: Maybe String
  , clType :: Maybe CardType
  , clCost :: Maybe Int
  , clBody :: Maybe (Int, Int)
  , clTags :: Maybe [String]
  , clKeywords :: Maybe [KwSpec]
  , clText :: Maybe String
  , clResolve :: Maybe [SExpr]
  , clOns :: [(Event, [SExpr])]
  , clActs :: [[SExpr]]
  , clAuras :: [[SExpr]]
  }

emptyClauses :: Clauses
emptyClauses = Clauses Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing [] [] []

validCardId :: String -> Bool
validCardId [a, b, c, '-', d, e, f] =
  all isAsciiUpper [a, b, c] && all isDigit [d, e, f]
validCardId _ = False

parseCard :: SExpr -> Maybe Card
parseCard (SList (SSym "card" : SSym cid : clauses)) = do
  unless (validCardId cid) Nothing
  cl <- foldM clause emptyClauses clauses
  name <- clName cl
  ty <- clType cl
  cost <- clCost cl
  when (cost < 0) Nothing
  body <- case (ty, clBody cl) of
    (Unit, Just b) -> Just (Just b)
    (Unit, Nothing) -> Nothing
    (_, Just _) -> Nothing
    (_, Nothing) -> Just Nothing
  let kws = maybe [] id (clKeywords cl)
  unless (all (kwLegal ty) kws) Nothing
  resolveAb <- case (ty, clResolve cl) of
    (Rite, Just parts) -> do
      (tg, tr, _, _, effs, raws) <- parseAbilityParts False parts
      Just [mk AKResolve tg tr [] Nothing effs [] raws]
    (Rite, Nothing) -> Nothing
    (_, Just _) -> Nothing
    (_, Nothing) -> Just []
  onAbs <- forM (clOns cl) $ \(ev, parts) -> do
    (tg, tr, _, _, effs, raws) <- parseAbilityParts False parts
    Just (mk (AKOn ev) tg tr [] Nothing effs [] raws)
  actAbs <- forM (clActs cl) $ \parts -> do
    (tg, tr, cs, craw, effs, raws) <- parseAbilityParts True parts
    cost' <- cs
    Just (mk AKAct tg tr cost' craw effs [] raws)
  auraAbs <- forM (clAuras cl) $ \sts -> do
    when (null sts) Nothing
    statics <- mapM pStatic sts
    Just (mk AKAura [] Nothing [] Nothing [] statics sts)
  let abs' = resolveAb ++ onAbs ++ actAbs ++ auraAbs
      numbered = zipWith (\i a -> a { abIndex = i }) [1 ..] abs'
  Just Card
    { cardId = cid, cardName = name, cardType = ty, cardCost = cost
    , cardBody = body, cardTags = maybe [] id (clTags cl)
    , cardKeywords = kws, cardAbilities = numbered }
  where
    mk kind tg tr cs craw effs sts raws =
      Ability { abIndex = 0, abKind = kind, abTargets = tg, abTargetsRaw = tr
              , abCost = cs, abCostRaw = craw, abEffects = effs
              , abStatics = sts, abRaw = raws }
parseCard _ = Nothing

kwLegal :: CardType -> KwSpec -> Bool
kwLegal Rite (KwSpec k _) = k == Swift
kwLegal Unit (KwSpec k _) = k /= Swift
kwLegal Relic _ = False

clause :: Clauses -> SExpr -> Maybe Clauses
clause cl (SList (SSym h : args)) = case (h, args) of
  ("name", [SStr s]) -> once clName (\v -> cl { clName = Just v }) s
  ("type", [SSym t]) -> do
    ty <- lookup t [("unit", Unit), ("rite", Rite), ("relic", Relic)]
    once clType (\v -> cl { clType = Just v }) ty
  ("cost", [SInt n]) -> once clCost (\v -> cl { clCost = Just v }) (fromInteger n)
  ("body", [SInt e, SInt c]) -> do
    when (e < 0 || c < 0) Nothing
    once clBody (\v -> cl { clBody = Just v }) (fromInteger e, fromInteger c)
  ("tags", ts) -> do
    syms <- mapM tagSym ts
    once clTags (\v -> cl { clTags = Just v }) syms
  ("keywords", ks) -> do
    specs <- mapM pKwSpecBare ks
    once clKeywords (\v -> cl { clKeywords = Just v }) specs
  ("text", [SStr s]) -> once clText (\v -> cl { clText = Just v }) s
  ("resolve", parts) -> once clResolve (\v -> cl { clResolve = Just v }) parts
  ("on", SSym ev : parts) -> do
    e <- eventFromName ev
    Just cl { clOns = clOns cl ++ [(e, parts)] }
  ("act", parts) -> Just cl { clActs = clActs cl ++ [parts] }
  ("aura", sts) -> Just cl { clAuras = clAuras cl ++ [sts] }
  _ -> Nothing
  where
    once get set v = if isJust (get cl) then Nothing else Just (set v)
    tagSym (SSym s) = Just s
    tagSym _ = Nothing
clause _ _ = Nothing

-- | A keyword spec as written in a @keywords@ list or a @grant@: a bare
-- keyword (not @plating@) or @(plating N)@.
pKwSpecBare :: SExpr -> Maybe KwSpec
pKwSpecBare (SSym s) = do
  k <- keywordFromName s
  when (k == Plating) Nothing
  Just (KwSpec k 0)
pKwSpecBare (SList [SSym "plating", SInt n]) = Just (KwSpec Plating (fromInteger n))
pKwSpecBare _ = Nothing

-- ---------------------------------------------------------------------------
-- Ability bodies

type Parts =
  ( [TSpec], Maybe SExpr, Maybe [CostItem], Maybe SExpr, [Effect], [SExpr] )

-- | Parse the parts of a @resolve@, @on@ or @act@ clause.  @isAct@ demands
-- exactly one @cost@ (and forbids it elsewhere).
parseAbilityParts :: Bool -> [SExpr] -> Maybe Parts
parseAbilityParts isAct parts = go parts [] Nothing Nothing False
  where
    -- state: accumulated effects (raw), targets, cost, seenEffect
    go [] effs tg cs _ = finish effs tg cs
    go (p : ps) effs tg cs seen = case p of
      SList (SSym "cost" : items)
        | not isAct || isJust cs || seen -> Nothing
        | otherwise -> do
            cis <- mapM pCostItem items
            go ps effs tg (Just (cis, p)) seen
      SList (SSym "targets" : specs)
        | isJust tg || seen -> Nothing
        | null specs -> Nothing
        | otherwise -> do
            ts <- mapM pTSpec specs
            go ps effs (Just (ts, p)) cs seen
      _ -> go ps (effs ++ [p]) tg cs True
    finish effs tg cs = do
      when (null effs) Nothing
      when (isAct && not (isJust cs)) Nothing
      parsed <- mapM pEffect effs
      Just ( maybe [] fst tg, fmap snd tg
           , fmap fst cs, fmap snd cs, parsed, effs )

pCostItem :: SExpr -> Maybe CostItem
pCostItem (SList [SSym "ember", SInt n]) = Just (CIEmber (fromInteger n))
pCostItem (SList [SSym "spire", SInt n]) = Just (CISpire (fromInteger n))
pCostItem (SList [SSym "discard", SInt n]) = Just (CIDiscard (fromInteger n))
pCostItem (SList [SSym "exhaust"]) = Just CIExhaust
pCostItem (SList [SSym "sacself"]) = Just CISacSelf
pCostItem (SList [SSym "counters", SInt n]) = Just (CICounters (fromInteger n))
pCostItem (SList [SSym "once"]) = Just CIOnce
pCostItem _ = Nothing

pTSpec :: SExpr -> Maybe TSpec
pTSpec (SList (SSym h : fs)) = case h of
  "unit" -> TUnit <$> mapM pFilter fs
  "relic" -> TRelic <$> mapM pFilter fs
  "any" -> TAny <$> mapM pFilter fs
  "ashcard" -> TAshCard <$> mapM pFilter fs
  "player" | null fs -> Just TPlayer
  "chained" | null fs -> Just TChained
  _ -> Nothing
pTSpec _ = Nothing

-- ---------------------------------------------------------------------------
-- Selectors, filters, amounts, conditions

pInt :: SExpr -> Maybe Int
pInt (SInt n) = Just (fromInteger n)
pInt _ = Nothing

pScope :: SExpr -> Maybe Scope
pScope (SSym "yours") = Just Yours
pScope (SSym "theirs") = Just Theirs
pScope (SSym "all") = Just AllScope
pScope _ = Nothing

pCmp :: SExpr -> Maybe Cmp
pCmp (SSym s) = cmpFromName s
pCmp _ = Nothing

pCardType :: SExpr -> Maybe CardType
pCardType (SSym t) = lookup t [("unit", Unit), ("rite", Rite), ("relic", Relic)]
pCardType _ = Nothing

pFilter :: SExpr -> Maybe Filter
pFilter (SList (SSym h : args)) = case (h, args) of
  ("kw", [SSym k]) -> FKw <$> keywordFromName k
  ("no-kw", [SSym k]) -> FNoKw <$> keywordFromName k
  ("tag", [SSym t]) -> Just (FTag t)
  ("type", [t]) -> FType <$> pCardType t
  ("cost", [c, n]) -> FCost <$> pCmp c <*> pInt n
  ("edge", [c, n]) -> FEdge <$> pCmp c <*> pInt n
  ("core", [c, n]) -> FCore <$> pCmp c <*> pInt n
  ("wounded", []) -> Just FWounded
  ("ready", []) -> Just FReady
  ("exhausted", []) -> Just FExhausted
  ("settling", []) -> Just FSettling
  ("attacking", []) -> Just FAttacking
  ("blocking", []) -> Just FBlocking
  ("mine", []) -> Just FMine
  ("enemy", []) -> Just FEnemy
  ("other", []) -> Just FOther
  ("not", [f]) -> FNot <$> pFilter f
  _ -> Nothing
pFilter _ = Nothing

pCardFilter :: SExpr -> Maybe CardFilter
pCardFilter (SList [SSym "type", t]) = CFType <$> pCardType t
pCardFilter (SList [SSym "tag", SSym t]) = Just (CFTag t)
pCardFilter (SList [SSym "cost", c, n]) = CFCost <$> pCmp c <*> pInt n
pCardFilter _ = Nothing

pCardZone :: SExpr -> Maybe CardZone
pCardZone (SSym z) = lookup z [("hand", CZHand), ("ash", CZAsh), ("vault", CZVault), ("rift", CZRift)]
pCardZone _ = Nothing

pSel :: SExpr -> Maybe Sel
pSel (SSym "self") = Just SelSelf
pSel (SSym "it") = Just SelIt
pSel (SSym "that") = Just SelThat
pSel (SList (SSym h : args)) = case (h, args) of
  ("t", [n]) -> SelTarget <$> pInt n
  ("units", s : fs) -> SelUnits <$> pScope s <*> mapM pFilter fs
  ("relics", s : fs) -> SelRelics <$> pScope s <*> mapM pFilter fs
  ("cards", z : s : fs) -> SelCards <$> pCardZone z <*> pScope s <*> mapM pFilter fs
  ("random-unit", s : fs) -> SelRandomUnit <$> pScope s <*> mapM pFilter fs
  _ -> Nothing
pSel _ = Nothing

pPSel :: SExpr -> Maybe PSel
pPSel (SSym "you") = Just PYou
pPSel (SSym "foe") = Just PFoe
pPSel (SSym "both") = Just PBoth
pPSel (SList [SSym "t", n]) = PTarget <$> pInt n
pPSel (SList [SSym "owner-of", s]) = POwnerOf <$> pSel s
pPSel _ = Nothing

pDSel :: SExpr -> Maybe DSel
pDSel e = case pPSel e of
  Just ps@(PYou) -> Just (DPlayers ps)
  Just ps@(PFoe) -> Just (DPlayers ps)
  Just ps@(PBoth) -> Just (DPlayers ps)
  Just ps@(POwnerOf _) -> Just (DPlayers ps)
  _ -> DObjects <$> pSel e

pAmt :: SExpr -> Maybe Amt
pAmt (SInt n) = Just (AInt (fromInteger n))
pAmt (SList [SSym h, a]) = case h of
  "count" -> ACount <$> pSel a
  "hand" -> AHand <$> pPSel a
  "ash" -> AAsh <$> pPSel a
  "vault" -> AVault <$> pPSel a
  "edge" -> AEdge <$> pSel a
  "core" -> ACore <$> pSel a
  "wounds" -> AWounds <$> pSel a
  _ -> Nothing
pAmt _ = Nothing

pCond :: SExpr -> Maybe Cond
pCond (SList (SSym h : args)) = case (h, args) of
  ("count", [s, c, n]) -> CCount <$> pSel s <*> pCmp c <*> pInt n
  ("spire", [p, c, n]) -> CSpire <$> pPSel p <*> pCmp c <*> pInt n
  ("hand", [p, c, n]) -> CHand <$> pPSel p <*> pCmp c <*> pInt n
  ("ash", [p, c, n]) -> CAsh <$> pPSel p <*> pCmp c <*> pInt n
  ("vault", [p, c, n]) -> CVault <$> pPSel p <*> pCmp c <*> pInt n
  ("ember", [p, c, n]) -> CEmber <$> pPSel p <*> pCmp c <*> pInt n
  ("myturn", []) -> Just CMyTurn
  ("and", cs) -> CAnd <$> mapM pCond cs
  ("or", cs) -> COr <$> mapM pCond cs
  ("not", [c]) -> CNot <$> pCond c
  _ -> Nothing
pCond _ = Nothing

pStatic :: SExpr -> Maybe Static
pStatic (SList (SSym h : args)) = case (h, args) of
  ("modify", [a, b, s]) -> StModify <$> pAmt a <*> pAmt b <*> pSel s
  ("setbody", [a, b, s]) -> StSetbody <$> pAmt a <*> pAmt b <*> pSel s
  ("swapstats", [s]) -> StSwapstats <$> pSel s
  ("grant", [k, s]) -> StGrant <$> pKwSpecBare k <*> pSel s
  ("cheaper", n : fs) -> StCheaper <$> pInt n <*> mapM pCardFilter fs
  ("when", c : sts) -> StWhen <$> pCond c <*> mapM pStatic sts
  _ -> Nothing
pStatic _ = Nothing

pEffects :: SExpr -> Maybe [Effect]
pEffects (SList es) = mapM pEffect es
pEffects _ = Nothing

pEffect :: SExpr -> Maybe Effect
pEffect (SList (SSym h : args)) = case (h, args) of
  ("damage", [a, d]) -> EDamage <$> pAmt a <*> pDSel d
  ("destroy", [s]) -> EDestroy <$> pSel s
  ("sacrifice", [s]) -> ESacrifice <$> pSel s
  ("exile", [s]) -> EExile <$> pSel s
  ("bounce", [s]) -> EBounce <$> pSel s
  ("draw", [a, p]) -> EDraw <$> pAmt a <*> pPSel p
  ("discard", [a, p]) -> EDiscard <$> pAmt a <*> pPSel p
  ("mill", [a, p]) -> EMill <$> pAmt a <*> pPSel p
  ("spire", [a, p]) -> ESpire <$> pAmt a <*> pPSel p
  ("ember", [a, p]) -> EEmber <$> pAmt a <*> pPSel p
  ("cap", [a, p]) -> ECap <$> pAmt a <*> pPSel p
  ("modify", [a, b, s]) -> EModify <$> pAmt a <*> pAmt b <*> pSel s
  ("setbody", [a, b, s]) -> ESetbody <$> pAmt a <*> pAmt b <*> pSel s
  ("swapstats", [s]) -> ESwapstats <$> pSel s
  ("grant", [k, s]) -> EGrant <$> pKwSpecBare k <*> pSel s
  ("strip", [s]) -> EStrip <$> pSel s
  ("control", [s]) -> EControl <$> pSel s
  ("counters", [a, s]) -> ECounters <$> pAmt a <*> pSel s
  ("ready", [s]) -> EReady <$> pSel s
  ("exhaust", [s]) -> EExhaust <$> pSel s
  ("doom", [s]) -> EDoom <$> pSel s
  ("ward", [a, s]) -> EWard <$> pAmt a <*> pSel s
  ("shield", [a, p]) -> EShield <$> pAmt a <*> pPSel p
  ("summon", [SSym c, a, p]) -> ESummon c <$> pAmt a <*> pPSel p
  ("conjure", [SSym c, a, p]) -> EConjure c <$> pAmt a <*> pPSel p
  ("reanimate", [s]) -> EReanimate <$> pSel s
  ("recall", [s]) -> ERecall <$> pSel s
  ("negate", [SList [SSym "t", n]]) -> ENegate <$> pInt n
  ("dig", [k, SList fs, p]) -> EDig <$> pInt k <*> mapM pFilter fs <*> pPSel p
  ("delay", SSym w : es) -> EDelay <$> whenFromName' w <*> mapM pEffect es
  ("if", [c, t]) -> EIf <$> pCond c <*> pEffects t <*> pure []
  ("if", [c, t, e]) -> EIf <$> pCond c <*> pEffects t <*> pEffects e
  ("each", s : es) -> EEach <$> pSel s <*> mapM pEffect es
  ("repeat", a : es) -> ERepeat <$> pAmt a <*> mapM pEffect es
  ("nothing", []) -> Just ENothing
  _ -> Nothing
  where whenFromName' = whenFromName
pEffect _ = Nothing
