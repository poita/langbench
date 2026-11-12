-- | Pattern usefulness, exhaustiveness and reachability (SPEC.md section 12.4).
module Langvm.Exhaust
  ( UPat (..)
  , UCtor (..)
  , useful
  ) where

import Data.Array ((!))
import qualified Data.IntMap.Strict as IM

import Langvm.Types

-- | A constructor named by a pattern.
data UCtor
  = UCBool Bool
  | UCTuple Int
  | UCStruct
  | UCVariant Int
  | UCInt Int
  | UCStr String
  | UCChar Char
  deriving (Eq, Show)

-- | A pattern as the usefulness algorithm sees it.
data UPat
  = UWild
  | UCon UCtor [UPat]
  | UListFix [UPat]
  | UListOpen [UPat]
  deriving (Show)

-- | The finite constructor set of a type, if it has one, with the component
-- types of each constructor.
allCtors :: Globals -> Ty -> Maybe [(UCtor, [Ty])]
allCtors g t = case t of
  TBool -> Just [(UCBool True, []), (UCBool False, [])]
  TTuple ts -> Just [(UCTuple (length ts), ts)]
  TNamed d args ->
    let di = gDecls g ! d
        sub = IM.fromList (zip (dParams di) args)
    in case dKind di of
         KStruct fs -> Just [(UCStruct, map (substTy sub . snd) fs)]
         KEnum vs -> Just [(UCVariant i, map (substTy sub) ts) | (i, (_, ts)) <- zip [0 ..] vs]
  _ -> Nothing

-- | @useful g tys rows q@: is row @q@ useful against the matrix @rows@?
useful :: Globals -> [Ty] -> [[UPat]] -> [UPat] -> Bool
useful _ [] rows [] = null rows
useful g (t : ts) rows (p : ps) = case t of
  TList e -> listRule e
  _ -> case p of
    UCon c subs -> useful g (ctorTys c ++ ts) (specialise c rows) (subs ++ ps)
    _ -> case allCtors g t of
      Just cs
        | all (\(c, _) -> c `elem` used) cs ->
            any (\(c, ctys) -> useful g (ctys ++ ts) (specialise c rows) (replicate (length ctys) UWild ++ ps)) cs
      _ -> useful g ts (defaultRows rows) ps
  where
    used = [c | (UCon c _ : _) <- rows]
    -- component types of the constructor named by q's first pattern
    ctorTys c = case allCtors g t of
      Just cs -> maybe (replicate (arityOf p) TUnit) id (lookup c cs)
      Nothing -> []
    arityOf (UCon _ subs) = length subs
    arityOf _ = 0
    specialise c = concatMap (specRow c)
    specRow c row = case row of
      (UCon c' subs : rest) | c' == c -> [subs ++ rest]
                            | otherwise -> []
      (UWild : rest) -> [replicate (ctorArity c) UWild ++ rest]
      _ -> []
    ctorArity c = case allCtors g t of
      Just cs -> maybe 0 length (lookup c cs)
      Nothing -> 0
    defaultRows = concatMap (\row -> case row of (UWild : rest) -> [rest]; _ -> [])
    listRule e =
      let firstLens = [n | (UListFix xs : _) <- rows, let n = length xs]
                   ++ [n | (UListOpen xs : _) <- rows, let n = length xs]
          qLen = case p of UListFix xs -> length xs; UListOpen xs -> length xs; _ -> 0
          lmax = maximum (0 : qLen : firstLens)
          admits k = case p of
            UWild -> True
            UListFix xs -> length xs == k
            UListOpen xs -> length xs <= k
            _ -> False
          specL k row = case row of
            (UListFix xs : rest) | length xs == k -> [xs ++ rest]
                                 | otherwise -> []
            (UListOpen xs : rest) | length xs <= k -> [xs ++ replicate (k - length xs) UWild ++ rest]
                                  | otherwise -> []
            (UWild : rest) -> [replicate k UWild ++ rest]
            _ -> []
          qSpec k = case p of
            UListFix xs -> xs ++ ps
            UListOpen xs -> xs ++ replicate (k - length xs) UWild ++ ps
            _ -> replicate k UWild ++ ps
      in any (\k -> admits k && useful g (replicate k e ++ ts) (concatMap (specL k) rows) (qSpec k))
             [0 .. lmax + 1]
useful _ _ _ _ = False
