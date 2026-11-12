module BuildSpec (spec) where

import Test.Hspec

import Support

spec :: Spec
spec = do
  it "runs a single step (specification example 1)" $
    buildLog "step {\n out \"out/hello.txt\"\n cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n" []
      `shouldBe` [ "  run 0 1 w0 out/hello.txt write(\"hello\\n\")"
                 , "  ok ran=1 hit=0 time=1"
                 ]
  it "allocates workers lowest-id-first and breaks ties by serial (example 3)" $
    drop 1 (runLog [("main.kiln", example3)] "build -j 2")
      `shouldSatisfy` (\ls -> take 5 ls == [ "  run 0 3 w0 out/a.txt write(\"A\\n\")"
                                           , "  run 0 1 w1 out/b.txt write(\"B\\n\")"
                                           , "  run 1 5 w1 out/c.txt write(\"C\\n\")"
                                           , "  run 3 5 w0 out/d.txt write(\"D\\n\")"
                                           , "  run 5 7 w0 out/all.txt concat()"
                                           ])
  describe "configuration errors" $ do
    let err m extra = buildLog m extra
        stepOut o = "step {\n out \"" ++ o ++ "\"\n cmd write(\"x\")\n}\n"
    it "E_NO_BUILD_FILE" $ runLog [] "build" `shouldBe` ["step 1: build (default) -j 1", "  error E_NO_BUILD_FILE main.kiln"]
    it "E_NO_DEFAULT" $ err (stepOut "out/a") [] `shouldBe` ["  error E_NO_DEFAULT"]
    it "E_DUP_OUTPUT" $
      err (stepOut "out/a" ++ stepOut "out/a" ++ "default \"out/a\"\n") [] `shouldBe` ["  error E_DUP_OUTPUT out/a"]
    it "E_OUTPUT_PATH" $ err (stepOut "src/a") [] `shouldBe` ["  error E_OUTPUT_PATH src/a"]
    it "E_UNKNOWN_TARGET from default" $ err "default \"nothing\"\n" [] `shouldBe` ["  error E_UNKNOWN_TARGET nothing"]
    it "E_MISSING_INPUT" $
      err "step {\n out \"out/a\"\n in \"src/x\"\n cmd copy()\n}\ndefault \"out/a\"\n" []
        `shouldBe` ["  error E_MISSING_INPUT src/x required by out/a"]
    it "E_CYCLE reports the cycle from the DFS" $
      err
        "step {\n out \"out/x\"\n in \"out/y\"\n cmd copy()\n}\nstep {\n out \"out/y\"\n in \"out/x\"\n cmd copy()\n}\ndefault \"out/x\"\n"
        []
        `shouldBe` ["  error E_CYCLE out/x -> out/y -> out/x"]
    it "E_ABORT" $ err "abort \"stop {1 + 1}\"\n" [] `shouldBe` ["  error E_ABORT stop 2"]
    it "E_PARSE names the file and line" $ err "let x = 1\nlet = 2\n" [] `shouldBe` ["  error E_PARSE main.kiln:2"]
    it "E_INCLUDE_CYCLE" $
      err "include \"a.kiln\"\n" [("a.kiln", "include \"a.kiln\"\n")] `shouldBe` ["  error E_INCLUDE_CYCLE a.kiln"]
    it "E_RULE_RECURSION at depth 65" $
      err "rule r() {\n use r()\n}\nuse r()\n" [] `shouldBe` ["  error E_RULE_RECURSION r"]
  describe "scoping" $ do
    it "rules see later bindings in their defining scope" $
      evalLike "rule r() {\n step {\n out \"out/x\"\n cmd write(v)\n }\n}\nlet v = \"late\"\nuse r()\ndefault \"out/x\"\n"
        `shouldBe` ["  run 0 1 w0 out/x write(\"late\")", "  ok ran=1 hit=0 time=1"]
    it "include shares the including scope" $
      evalLike "include \"i.kiln\"\nstep {\n out \"out/x\"\n cmd write(v)\n}\ndefault \"out/x\"\n"
        `shouldBe` ["  run 0 1 w0 out/x write(\"1\")", "  ok ran=1 hit=0 time=1"]
  where
    evalLike m = buildLog m [("i.kiln", "let v = \"1\"\n")]
    example3 =
      unlines
        [ "step {\n out \"out/a.txt\"\n cmd write(\"A\\n\")\n cost 3\n}"
        , "step {\n out \"out/b.txt\"\n cmd write(\"B\\n\")\n cost 1\n}"
        , "step {\n out \"out/c.txt\"\n cmd write(\"C\\n\")\n cost 4\n}"
        , "step {\n out \"out/d.txt\"\n cmd write(\"D\\n\")\n cost 2\n}"
        , "step {\n out \"out/all.txt\"\n in [\"out/a.txt\", \"out/b.txt\", \"out/c.txt\", \"out/d.txt\"]\n cmd concat()\n cost 2\n}"
        , "default \"out/all.txt\""
        ]
