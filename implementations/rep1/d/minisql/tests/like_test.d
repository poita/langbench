module tests.like_test;

import minisql.like;

unittest
{
    assert(likeMatch("apple", "apple"));
    assert(likeMatch("APPLE", "apple"));
    assert(likeMatch("Apple", "a%"));
    assert(likeMatch("abc", "%"));
    assert(likeMatch("", "%"));
    assert(!likeMatch("", "_"));
    assert(likeMatch("abc", "a_c"));
    assert(!likeMatch("abc", "a_"));
    assert(likeMatch("abcabc", "%bc"));
    assert(!likeMatch("abcabd", "%bc"));
    assert(likeMatch("xxaxxbxx", "%a%b%"));
    assert(likeMatch("Ab_c", "ab%"));
    assert(!likeMatch("ab", "abc"));
}

unittest // only ASCII letters fold
{
    assert(!likeMatch("É", "é"));
    assert(likeMatch("É", "É"));
}

unittest // `_` consumes a whole UTF-8 sequence, also after backtracking
{
    assert(likeMatch("é", "_"));
    assert(!likeMatch("é", "__"));
    assert(likeMatch("aéb", "a_b"));
    assert(likeMatch("日本語", "%_"));
    assert(likeMatch("日本語", "_本_"));
    assert(!likeMatch("日", "__"));
    assert(likeMatch("éaé", "%a_"));
}
