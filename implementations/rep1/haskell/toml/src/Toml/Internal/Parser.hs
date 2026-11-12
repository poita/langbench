-- | A minimal backtracking-free parser monad over strict 'Text'.
--
-- Every primitive is O(1) or bounded by the length of the token it consumes,
-- so parsers built on it are linear in the input.
module Toml.Internal.Parser
  ( P
  , Res (..)
  , runP
  , failP
  , liftE
  , peekChar
  , nextChar
  , dropP
  , takeWhileP
  , skipWhileP
  , takeN
  , lookingAt
  , expectChar
  , expectText
  , remaining
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | The result of running a parser: failure carries a message and the input
-- that was left at the point of failure.
data Res a = Fail String !Text | Ok a !Text

newtype P a = P {unP :: Text -> Res a}

instance Functor P where
  fmap f (P p) = P $ \t -> case p t of
    Ok a t' -> Ok (f a) t'
    Fail m r -> Fail m r

instance Applicative P where
  pure a = P (Ok a)
  P pf <*> P pa = P $ \t -> case pf t of
    Fail m r -> Fail m r
    Ok f t' -> case pa t' of
      Ok a t'' -> Ok (f a) t''
      Fail m r -> Fail m r

instance Monad P where
  P p >>= f = P $ \t -> case p t of
    Fail m r -> Fail m r
    Ok a t' -> unP (f a) t'

runP :: P a -> Text -> Res a
runP = unP

failP :: String -> P a
failP msg = P (Fail msg)

-- | Lift a pure error into the parser.
liftE :: Either String a -> P a
liftE (Right a) = pure a
liftE (Left m) = failP m

peekChar :: P (Maybe Char)
peekChar = P $ \t -> Ok (fst <$> T.uncons t) t

nextChar :: P Char
nextChar = P $ \t -> case T.uncons t of
  Nothing -> Fail "unexpected end of input" t
  Just (c, t') -> Ok c t'

-- | Drop @n@ characters (the caller has already looked at them).
dropP :: Int -> P ()
dropP n = P $ \t -> Ok () (T.drop n t)

takeWhileP :: (Char -> Bool) -> P Text
takeWhileP p = P $ \t -> let (a, b) = T.span p t in Ok a b

skipWhileP :: (Char -> Bool) -> P ()
skipWhileP p = P $ \t -> Ok () (T.dropWhile p t)

-- | Take exactly @n@ characters, failing if the input is shorter.
takeN :: Int -> P Text
takeN n = P $ \t ->
  let (a, b) = T.splitAt n t
  in if T.length a == n then Ok a b else Fail "unexpected end of input" t

-- | Is the input positioned at the given text?
lookingAt :: Text -> P Bool
lookingAt s = P $ \t -> Ok (s `T.isPrefixOf` t) t

expectChar :: Char -> P ()
expectChar c = P $ \t -> case T.uncons t of
  Just (c', t') | c == c' -> Ok () t'
  _ -> Fail ("expected " ++ show c) t

expectText :: Text -> P ()
expectText s = P $ \t -> case T.stripPrefix s t of
  Just t' -> Ok () t'
  Nothing -> Fail ("expected " ++ show (T.unpack s)) t

remaining :: P Text
remaining = P $ \t -> Ok t t
