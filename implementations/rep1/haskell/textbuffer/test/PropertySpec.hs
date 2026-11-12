module PropertySpec (spec) where

import qualified Data.ByteString.Char8 as B
import Data.List (sortOn)
import Test.Hspec
import Test.QuickCheck

import TextBuffer
import qualified TextBuffer.Document as Doc

genText :: Gen String
genText = listOf1 (elements "ab \n")

genCommand :: Gen Command
genCommand = frequency
  [ (4, Insert . B.pack <$> genText)
  , (2, pure Delete)
  , (2, pure DeleteForward)
  , (4, Move <$> elements [minBound .. maxBound] <*> arbitrary)
  , (2, Goto <$> choose (0, 6) <*> choose (0, 8))
  , (3, AddCursor <$> choose (0, 6) <*> choose (0, 8))
  , (1, pure ClearCursors)
  ]

genEdit :: Gen Command
genEdit = oneof [Insert . B.pack <$> genText, pure Delete, pure DeleteForward]

genLines :: Gen [B.ByteString]
genLines = listOf (B.pack <$> listOf (elements "abc "))

-- | State summary that must be restored exactly by undo.
snapshot :: Buffer -> (B.ByteString, [(Pos, Maybe Pos, Bool)])
snapshot b = ( Doc.toText (document b)
             , [(curHead c, curAnchor c, curPrimary c) | c <- cursors b] )

invariants :: Buffer -> Bool
invariants b = and
  [ length (filter curPrimary cs) == 1
  , all valid cs
  , and (zipWith (<) (map rangeStart cs) (drop 1 (map rangeStart cs)))
  , and (zipWith (<=) (map rangeEnd cs) (drop 1 (map rangeStart cs)))
  , map rangeStart cs == map rangeStart (sortOn rangeStart cs)
  ]
  where
    d = document b
    cs = cursors b
    ok p = p == Doc.clampPos d p
    valid c = ok (curHead c) && maybe True (\a -> ok a && a /= curHead c) (curAnchor c)

spec :: Spec
spec = do
  it "keeps cursor invariants under random commands" $
    property $ forAll genLines $ \ls -> forAll (listOf genCommand) $ \cmds ->
      all invariants (scanl (flip execute) (fromLines ls) cmds)
  it "undoing every edit restores the initial document" $
    property $ forAll genLines $ \ls -> forAll (listOf genCommand) $ \cmds ->
      let b0 = fromLines ls
          b = foldl (flip execute) b0 cmds
          unwound = until (not . canUndo) (execute Undo) b
      in fst (snapshot unwound) === fst (snapshot b0)
  it "undo then redo after an edit returns to the same state" $
    property $ forAll genLines $ \ls -> forAll (listOf genCommand) $ \cmds ->
      forAll genEdit $ \e ->
        let prev = foldl (flip execute) (fromLines ls) cmds
            b = execute e prev
        in fst (snapshot b) /= fst (snapshot prev)
             ==> snapshot (execute Redo (execute Undo b)) === snapshot b
  it "undo restores the state before a text-changing edit" $
    property $ forAll genLines $ \ls -> forAll (listOf genCommand) $ \cmds ->
      forAll genEdit $ \c ->
        let prev = foldl (flip execute) (fromLines ls) cmds
            next = execute c prev
        in fst (snapshot next) /= fst (snapshot prev)
             ==> snapshot (execute Undo next) === snapshot prev
  it "single-cursor typing matches a list model" $
    property $ forAll (listOf1 (elements "xyz")) $ \s ->
      let b = foldl (\acc ch -> execute (Insert (B.singleton ch)) acc)
                    (fromLines [B.pack "<>"]) s
      in Doc.toText (document b) === B.pack (s ++ "<>")
