{-# LANGUAGE OverloadedStrings #-}
module Spreadsheet.ScriptSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import Spreadsheet

spec :: Spec
spec = do
  it "example 1: a cycle created and broken" $
    runCommands
      [ "set A1 10", "set A2 32", "set A3 =A1+A2", "get A3", "set A1 =A3", "get A1"
      , "get A3", "set A1 5", "get A3", "dump" ]
      `shouldBe` ["42", "#CYCLE!", "#CYCLE!", "37", "A1 5", "A2 32", "A3 37"]
  it "example 2: strings, ranges, IF, error propagation" $
    runCommands
      [ "set A1 \"Total\"", "set B1 3", "set B2 4.5", "set B3 \"x\"", "set C1 =SUM(B1:B3)"
      , "set C2 =A1&\": \"&C1", "set C3 =IF(C1>7, \"big\", \"small\")", "set C4 =AVG(B1:B3)"
      , "set C5 =COUNT(B1:B3)", "set C6 =B1/(B2-4.5)", "set C7 =C6+1", "set C8 =1/3", "dump" ]
      `shouldBe` [ "A1 Total", "B1 3", "C1 7.5", "B2 4.5", "C2 Total: 7.5", "B3 x", "C3 big"
                 , "C4 3.75", "C5 2", "C6 #DIV/0!", "C7 #DIV/0!", "C8 0.3333333333" ]
  it "example 3: precedence, number formatting, clearing" $
    runCommands
      [ "set A1 =1+2*3", "set A2 =(1+2)*3", "set A3 =-2*3-4", "set A4 =2*-3", "set A5 =1<2+3"
      , "set A6 =1+2&3", "set A7 =100000000000000000000", "set A8 =0.00001", "set A9 =1234567.891"
      , "set A10 =2/3*3", "set B1 =A9", "clear A9", "get B1", "dump" ]
      `shouldBe` [ "0", "A1 7", "B1 0", "A2 9", "A3 -10", "A4 -6", "A5 1", "A6 33", "A7 1e+20"
                 , "A8 1e-05", "A10 2" ]
  it "prints an empty line for an empty cell and nothing for an empty dump" $
    runCommands ["get A1", "dump"] `shouldBe` [""]
  it "dumps an empty string cell" $
    runCommands ["set A1 \"\"", "dump"] `shouldBe` ["A1 "]
  it "keeps spaces inside string literals" $
    runCommands ["set A1 \" a  b \"", "get A1"] `shouldBe` [" a  b "]
  it "evaluates the spec's empty-cell examples" $
    runCommands
      [ "set A1 =(Z1)&\"x\"", "set A2 =IF(1,Z1,7)&\"x\"", "set A3 =(Z1)=\"\"", "set A4 =COUNT((Z1))"
      , "set A5 =-Z1&\"x\"", "dump" ]
      `shouldBe` ["A1 x", "A2 x", "A3 1", "A4 0", "A5 0x"]
  describe "parseCommand" $ do
    it "parses each command" $ do
      fmap isSet (parseCommand "set A1 =1") `shouldBe` Right True
      parseCommand "dump" `shouldBe` Right CmdDump
      fmap isSet (parseCommand "get A1") `shouldBe` Right False
    it "rejects bad lines" $
      mapM_ (\l -> parseCommand l `shouldSatisfy` isLeft) ["", "bogus", "get a1", "get AAA1", "dump x", "set A1 abc"]
  where
    isSet :: Command -> Bool
    isSet (CmdSet _ _) = True
    isSet _ = False

