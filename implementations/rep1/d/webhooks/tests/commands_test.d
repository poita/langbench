module commands_test;

import webhooks.commands : processString;

@("commands: spec section 3.3 examples")
unittest
{
    enum P = "7b2274657374223a20323433323233323331347d";
    enum H = "76312c6730684d395373452b4f54504a5447742f746d494b7453795a6c453375464a454c566c4e494f4c4a314f453d";
    enum S = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    enum I = "msg_p5jXN8AQM9LWM0D4loKWxJek";
    enum input = "sha256 -\nsha256 616263\nhmac - -\nb64enc 666f6f\nb64urlenc fbff\nb64dec 5a6d3976\nb64dec -\n"
        ~ "secret " ~ S ~ "\nsign " ~ S ~ " " ~ I ~ " 1614265330 " ~ P ~ "\n"
        ~ "verify " ~ S ~ " " ~ I ~ " 1614265330 1614265400 " ~ H ~ " " ~ P ~ "\n"
        ~ "verify " ~ S ~ " " ~ I ~ " 1614265330 1614265631 " ~ H ~ " " ~ P ~ "\n"
        ~ "verify " ~ S ~ " " ~ I ~ " 1614265330 1614265400 " ~ H ~ " 7b7d\n"
        ~ "verify " ~ S ~ " " ~ I ~ " 1614265330 1614265400 - " ~ P ~ "\n"
        ~ "sha256 ABCD\nsha256 abc\nfrobnicate 1\n";
    enum expected = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"
        ~ "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n"
        ~ "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad\n"
        ~ "Zm9v\n-_8\n666f6f\n-\n31f290f6bf06298aab4f08d43c3f082cf648a362da2da4b0\n"
        ~ "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=\nok 0 0\nfail timestamp-too-old\n"
        ~ "fail no-match\nfail missing-signature\nerror\nerror\nerror\n";
    assert(processString(input) == expected);
}

@("commands: blank lines are ignored, empty fields are errors")
unittest
{
    assert(processString("\n   \nsha256 -\n\n") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
    assert(processString("sha256  -\n") == "error\n");
    assert(processString(" sha256 -\n") == "error\n");
    assert(processString("sha256 -  \n") == "error\n");
    assert(processString("sha256\t-\n") == "error\n");
    assert(processString("sha256 -") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n");
}

@("commands: b64dec edge cases")
unittest
{
    assert(processString("b64dec 5151\n") == "41\n");          // "QQ"
    assert(processString("b64dec 51513d3d\n") == "41\n");      // "QQ==", trailing bits dropped
    assert(processString("b64dec 51\n") == "error\n");         // "Q": length mod 4 == 1
    assert(processString("b64dec 2b2d\n") == "error\n");       // "+-": mixed alphabets
    assert(processString("b64dec 5a6d3976 \n") == "error\n");   // trailing space is an empty field
}

@("commands: sign and verify argument validation")
unittest
{
    assert(processString("sign QQ id 007 -\n") == "error\n");
    assert(processString("sign QQ id +5 -\n") == "error\n");
    assert(processString("sign whsec_ id 5 -\n") == "error\n");
    // verify accepts a non-canonical timestamp and reports it as data.
    assert(processString("verify QQ id 007 5 3176312c78 -\n") == "fail invalid-timestamp\n");
    // but `now` must be canonical
    assert(processString("verify QQ id 7 05 3176312c78 -\n") == "error\n");
}
