-- |
-- Module      : Spiremark.Match
-- Description : Parser for match files (SPEC.md section 4).
--
-- A match file is a setup block terminated by @START@ followed by script
-- lines.  Setup errors are reported as 'SetupError'; script lines are parsed
-- individually so that a malformed one can be answered with @ERR ... bad-syntax@
-- while the match carries on.
module Spiremark.Match
  ( Setup (..)
  , TraceMode (..)
  , Action (..)
  , ScriptLine (..)
  , parseMatch
  , parseScriptLine
  , defaultSetup
  ) where

import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Word (Word64)

import Spiremark.Types

-- | Automatic block printed after every accepted action.
data TraceMode = TraceNone | TraceLegal | TraceState
  deriving (Eq, Show)

-- | Everything the setup block configures.
data Setup = Setup
  { suCards     :: FilePath
  , suSeed      :: Word64
  , suSpire     :: Int
  , suOpening   :: Int
  , suMaxCap    :: Int
  , suHandMax   :: Int
  , suTurnLimit :: Int
  , suFirst     :: Player
  , suShuffle   :: Bool
  , suTrace     :: TraceMode
  , suCapA      :: Int
  , suCapB      :: Int
  , suZones     :: [(Player, ZoneKind, [(String, Int)])]
    -- ^ card entries in the order the lines appeared (already count-expanded
    -- lazily: each pair is a card id and a copy count)
  } deriving (Eq, Show)

-- | The defaults of SPEC.md 4.1 (with empty @CARDS@ and seed 0 placeholders).
defaultSetup :: Setup
defaultSetup = Setup
  { suCards = "", suSeed = 0, suSpire = 25, suOpening = 5, suMaxCap = 10
  , suHandMax = 7, suTurnLimit = 200, suFirst = A, suShuffle = True
  , suTrace = TraceNone, suCapA = 0, suCapB = 0, suZones = [] }

-- | A player action (SPEC.md 4.2).
data Action
  = Pass
  | Concede
  | Play Int [Target]
  | Act Int Int [Target]
  | Attack [Int]
  | Block [(Int, Int)]
  deriving (Eq, Show)

-- | One parsed script line.
data ScriptLine
  = SAction Player Action
  | SDump
  | SLegal
  | SVault
  | SCard String
  | SBadSyntax
  deriving (Eq, Show)

-- | Split a match file into setup and numbered script lines.  Left means
-- @bad-setup@.
parseMatch :: String -> Either () (Setup, [(Int, String)])
parseMatch input = go 1 (splitLines input) defaultSetup []
  where
    go :: Int -> [String] -> Setup -> [String] -> Either () (Setup, [(Int, String)])
    go _ [] _ _ = Left ()
    go n (l : ls) su used
      | isComment l = go (n + 1) ls su used
      | otherwise =
          let ws = words' l
           in case ws of
                ["START"] -> finish n ls su used
                ("START" : _) -> Left ()
                (w : rest) -> do
                  (su', used') <- setupLine w rest su used
                  go (n + 1) ls su' used'
                [] -> go (n + 1) ls su used
    finish n ls su used
      | "CARDS" `notElem` used || "SEED" `notElem` used = Left ()
      | otherwise = Right (su, zip [n + 1 ..] ls)
    setupLine w rest su used = case w of
      "CARDS" -> once "CARDS" used $ case rest of
        [p] -> Right su { suCards = p }
        _ -> Left ()
      "SEED" -> once "SEED" used $ case rest of
        [x] -> do v <- numRange 0 (2 ^ (64 :: Int) - 1) x
                  Right su { suSeed = fromInteger v }
        _ -> Left ()
      "SPIRE" -> once "SPIRE" used $ num1 rest 1 1000000 (\v -> su { suSpire = v })
      "OPENING" -> once "OPENING" used $ num1 rest 0 20 (\v -> su { suOpening = v })
      "MAXCAP" -> once "MAXCAP" used $ num1 rest 1 100 (\v -> su { suMaxCap = v })
      "HANDMAX" -> once "HANDMAX" used $ num1 rest 0 100 (\v -> su { suHandMax = v })
      "TURNLIMIT" -> once "TURNLIMIT" used $ num1 rest 1 100000 (\v -> su { suTurnLimit = v })
      "FIRST" -> once "FIRST" used $ case rest of
        ["A"] -> Right su { suFirst = A }
        ["B"] -> Right su { suFirst = B }
        _ -> Left ()
      "SHUFFLE" -> once "SHUFFLE" used $ case rest of
        ["on"] -> Right su { suShuffle = True }
        ["off"] -> Right su { suShuffle = False }
        _ -> Left ()
      "TRACE" -> once "TRACE" used $ case rest of
        ["none"] -> Right su { suTrace = TraceNone }
        ["legal"] -> Right su { suTrace = TraceLegal }
        ["state"] -> Right su { suTrace = TraceState }
        _ -> Left ()
      "CAP" -> case rest of
        ["A", x] -> once "CAP A" used $ do
          v <- numRange 0 100 x
          Right su { suCapA = fromInteger v }
        ["B", x] -> once "CAP B" used $ do
          v <- numRange 0 100 x
          Right su { suCapB = fromInteger v }
        _ -> Left ()
      "DECK" -> zoneLine ZDeck rest su used
      "HAND" -> zoneLine ZHand rest su used
      "FIELD" -> zoneLine ZField rest su used
      "ASH" -> zoneLine ZAsh rest su used
      "RIFT" -> zoneLine ZRift rest su used
      _ -> Left ()
    once tag used act
      | tag `elem` used = Left ()
      | otherwise = fmap (\su' -> (su', tag : used)) act
    num1 rest lo hi f = case rest of
      [x] -> do v <- numRange lo hi x
                Right (f (fromInteger v))
      _ -> Left ()
    zoneLine zk rest su used = case rest of
      (pw : entries@(_ : _)) -> do
        p <- case pw of
          "A" -> Right A
          "B" -> Right B
          _ -> Left ()
        es <- mapM entry entries
        Right (su { suZones = suZones su ++ [(p, zk, es)] }, used)
      _ -> Left ()
    entry w = case break (== '*') w of
      ("", _) -> Left ()
      (cid, "") -> Right (cid, 1)
      (cid, '*' : cnt)
        | '*' `elem` cnt -> Left ()
        | otherwise -> do
            v <- numRange 1 1000 cnt
            Right (cid, fromInteger v)
      _ -> Left ()

numRange :: Integer -> Integer -> String -> Either () Integer
numRange lo hi s
  | not (null s) && all isDigit s =
      let v = read s :: Integer
       in if v >= lo && v <= hi then Right v else Left ()
  | otherwise = Left ()

isComment :: String -> Bool
isComment l = case dropWhile isWsC l of
  [] -> True
  ('#' : _) -> True
  _ -> False

isWsC :: Char -> Bool
isWsC c = c == ' ' || c == '\t'

words' :: String -> [String]
words' s = case dropWhile isWsC s of
  [] -> []
  s' -> let (w, r) = break isWsC s' in w : words' r

-- | Split on @\\n@, stripping one @\\r@ before each @\\n@; a final newline does
-- not create an extra empty line.
splitLines :: String -> [String]
splitLines s = case s of
  [] -> []
  _ -> let (l, r) = break (== '\n') s
           l' = if not (null l) && last l == '\r' then init l else l
        in l' : case r of
             [] -> []
             (_ : r') -> splitLines r'

-- | Parse one script line (never a comment; callers filter those).
parseScriptLine :: String -> ScriptLine
parseScriptLine l = case words' l of
  ["DUMP"] -> SDump
  ["LEGAL"] -> SLegal
  ["VAULT"] -> SVault
  ["CARD", cid] -> SCard cid
  (pw : aw : rest) | Just p <- player pw -> fromMaybe SBadSyntax (SAction p <$> action aw rest)
  _ -> SBadSyntax
  where
    player "A" = Just A
    player "B" = Just B
    player _ = Nothing

action :: String -> [String] -> Maybe Action
action w rest = case w of
  "PASS" | null rest -> Just Pass
  "CONCEDE" | null rest -> Just Concede
  "PLAY" -> case rest of
    (p : ts) -> Play <$> num p <*> mapM target ts
    _ -> Nothing
  "ACT" -> case rest of
    (o : i : ts) -> Act <$> objref o <*> num i <*> mapM target ts
    _ -> Nothing
  "ATTACK" -> Attack <$> mapM objref rest
  "BLOCK" -> Block <$> mapM pair rest
  _ -> Nothing
  where
    pair s = case break (== ':') s of
      (a, ':' : b) -> (,) <$> objref a <*> objref b
      _ -> Nothing

-- | A decimal that fits in 64 bits, saturated into an 'Int'.
num :: String -> Maybe Int
num s
  | not (null s) && all isDigit s =
      let v = read s :: Integer
       in if v < 2 ^ (64 :: Int) then Just (fromInteger (min v (toInteger (maxBound :: Int)))) else Nothing
  | otherwise = Nothing

objref :: String -> Maybe Int
objref ('#' : s) = num s
objref _ = Nothing

target :: String -> Maybe Target
target "A" = Just (TgtPlayer A)
target "B" = Just (TgtPlayer B)
target ('#' : s) = TgtObj <$> num s
target ('~' : s) = TgtEntry <$> num s
target _ = Nothing
