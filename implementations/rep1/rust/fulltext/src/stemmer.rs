//! The Porter stemming algorithm (1980), as implemented in Martin Porter's
//! reference `porter.c`, including its two departures from the paper
//! (`BLI -> BLE` and `LOGI -> LOG` in step 2).

/// Returns the Porter stem of a word made of ASCII lower-case letters.
///
/// Words of one or two letters are returned unchanged.
pub fn stem(word: &str) -> String {
    if word.len() <= 2 {
        return word.to_string();
    }
    let mut w = Word { b: word.as_bytes().to_vec() };
    w.step1a();
    w.step1b();
    w.step1c();
    w.step2();
    w.step3();
    w.step4();
    w.step5();
    String::from_utf8(w.b).expect("stemmer only handles ASCII")
}

struct Word {
    b: Vec<u8>,
}

impl Word {
    /// Is `b[i]` a consonant?
    fn cons(&self, i: usize) -> bool {
        match self.b[i] {
            b'a' | b'e' | b'i' | b'o' | b'u' => false,
            b'y' => i == 0 || !self.cons(i - 1),
            _ => true,
        }
    }

    /// The measure of the prefix `b[..n]`.
    fn measure(&self, n: usize) -> usize {
        let mut m = 0;
        let mut i = 0;
        // Skip the initial consonants.
        while i < n && self.cons(i) {
            i += 1;
        }
        loop {
            // Vowel run.
            while i < n && !self.cons(i) {
                i += 1;
            }
            if i >= n {
                return m;
            }
            // Consonant run completes a VC pair.
            while i < n && self.cons(i) {
                i += 1;
            }
            m += 1;
        }
    }

    /// Does the prefix `b[..n]` contain a vowel?
    fn has_vowel(&self, n: usize) -> bool {
        (0..n).any(|i| !self.cons(i))
    }

    /// `*d`: does the prefix `b[..n]` end in a double consonant?
    fn double_cons(&self, n: usize) -> bool {
        n >= 2 && self.b[n - 1] == self.b[n - 2] && self.cons(n - 1)
    }

    /// `*o`: does the prefix `b[..n]` end consonant-vowel-consonant with the
    /// last consonant not w, x or y?
    fn cvc(&self, n: usize) -> bool {
        n >= 3
            && self.cons(n - 3)
            && !self.cons(n - 2)
            && self.cons(n - 1)
            && !matches!(self.b[n - 1], b'w' | b'x' | b'y')
    }

    fn ends(&self, suffix: &str) -> bool {
        self.b.ends_with(suffix.as_bytes())
    }

    /// Replaces the last `suffix_len` bytes with `rep`.
    fn replace(&mut self, suffix_len: usize, rep: &str) {
        let n = self.b.len() - suffix_len;
        self.b.truncate(n);
        self.b.extend_from_slice(rep.as_bytes());
    }

    /// Applies the first rule in `rules` whose suffix matches, if its measure
    /// condition `m > min_m` holds. Later rules are never tried.
    fn apply_rules(&mut self, rules: &[(&str, &str)], min_m: usize) {
        for &(suffix, rep) in rules {
            if self.ends(suffix) {
                let stem_len = self.b.len() - suffix.len();
                if self.measure(stem_len) > min_m {
                    self.replace(suffix.len(), rep);
                }
                return;
            }
        }
    }

    fn step1a(&mut self) {
        if self.ends("sses") {
            self.replace(2, "");
        } else if self.ends("ies") {
            self.replace(2, "");
        } else if self.ends("ss") {
            // unchanged
        } else if self.ends("s") {
            self.replace(1, "");
        }
    }

    fn step1b(&mut self) {
        let len = self.b.len();
        let removed = if self.ends("eed") {
            if self.measure(len - 3) > 0 {
                self.replace(1, "");
            }
            false
        } else if self.ends("ed") {
            if self.has_vowel(len - 2) {
                self.replace(2, "");
                true
            } else {
                false
            }
        } else if self.ends("ing") {
            if self.has_vowel(len - 3) {
                self.replace(3, "");
                true
            } else {
                false
            }
        } else {
            false
        };
        if !removed {
            return;
        }
        let n = self.b.len();
        if self.ends("at") {
            self.replace(2, "ate");
        } else if self.ends("bl") {
            self.replace(2, "ble");
        } else if self.ends("iz") {
            self.replace(2, "ize");
        } else if self.double_cons(n) {
            if !matches!(self.b[n - 1], b'l' | b's' | b'z') {
                self.b.pop();
            }
        } else if self.measure(n) == 1 && self.cvc(n) {
            self.b.push(b'e');
        }
    }

    fn step1c(&mut self) {
        let n = self.b.len();
        if self.ends("y") && self.has_vowel(n - 1) {
            self.b[n - 1] = b'i';
        }
    }

    fn step2(&mut self) {
        const RULES: [(&str, &str); 21] = [
            ("ational", "ate"),
            ("tional", "tion"),
            ("enci", "ence"),
            ("anci", "ance"),
            ("izer", "ize"),
            ("bli", "ble"),
            ("alli", "al"),
            ("entli", "ent"),
            ("eli", "e"),
            ("ousli", "ous"),
            ("ization", "ize"),
            ("ation", "ate"),
            ("ator", "ate"),
            ("alism", "al"),
            ("iveness", "ive"),
            ("fulness", "ful"),
            ("ousness", "ous"),
            ("aliti", "al"),
            ("iviti", "ive"),
            ("biliti", "ble"),
            ("logi", "log"),
        ];
        self.apply_rules(&RULES, 0);
    }

    fn step3(&mut self) {
        const RULES: [(&str, &str); 7] = [
            ("icate", "ic"),
            ("ative", ""),
            ("alize", "al"),
            ("iciti", "ic"),
            ("ical", "ic"),
            ("ful", ""),
            ("ness", ""),
        ];
        self.apply_rules(&RULES, 0);
    }

    fn step4(&mut self) {
        const SUFFIXES: [&str; 19] = [
            "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent", "ion",
            "ou", "ism", "ate", "iti", "ous", "ive", "ize",
        ];
        for suffix in SUFFIXES {
            if !self.ends(suffix) {
                continue;
            }
            let stem_len = self.b.len() - suffix.len();
            let ok = self.measure(stem_len) > 1
                && (suffix != "ion"
                    || (stem_len > 0 && matches!(self.b[stem_len - 1], b's' | b't')));
            if ok {
                self.b.truncate(stem_len);
            }
            return;
        }
    }

    fn step5(&mut self) {
        // 5a
        if self.ends("e") {
            let n = self.b.len() - 1;
            let m = self.measure(n);
            if m > 1 || (m == 1 && !self.cvc(n)) {
                self.b.pop();
            }
        }
        // 5b
        let n = self.b.len();
        if self.b[n - 1] == b'l' && self.double_cons(n) && self.measure(n) > 1 {
            self.b.pop();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::stem;

    #[test]
    fn spec_worked_stems() {
        let cases = [
            ("running", "run"),
            ("runs", "run"),
            ("runner", "runner"),
            ("connection", "connect"),
            ("connections", "connect"),
            ("connecting", "connect"),
            ("cats", "cat"),
            ("dogs", "dog"),
            ("happiness", "happi"),
            ("happier", "happier"),
            ("relational", "relat"),
            ("relativity", "rel"),
            ("sensibility", "sensibl"),
            ("national", "nation"),
            ("controlled", "control"),
            ("abandoned", "abandon"),
        ];
        for (w, s) in cases {
            assert_eq!(stem(w), s, "stem of {w}");
        }
    }

    #[test]
    fn step_1b_selection_rule() {
        for w in ["feed", "need", "bleed", "deed"] {
            assert_eq!(stem(w), w);
        }
        assert_eq!(stem("agreed"), "agre");
    }

    #[test]
    fn step_1_examples() {
        let cases = [
            ("caresses", "caress"),
            ("ponies", "poni"),
            ("ties", "ti"),
            ("caress", "caress"),
            ("plastered", "plaster"),
            ("bled", "bled"),
            ("motoring", "motor"),
            ("sing", "sing"),
            ("conflated", "conflat"),
            ("troubled", "troubl"),
            ("sized", "size"),
            ("hopping", "hop"),
            ("falling", "fall"),
            ("fizzed", "fizz"),
            ("filing", "file"),
            ("failing", "fail"),
            ("happy", "happi"),
            ("sky", "sky"),
        ];
        for (w, s) in cases {
            assert_eq!(stem(w), s, "stem of {w}");
        }
    }

    #[test]
    fn short_words_unchanged() {
        for w in ["a", "is", "as", "us", "by"] {
            assert_eq!(stem(w), w);
        }
    }

    #[test]
    fn step_5() {
        assert_eq!(stem("probate"), "probat");
        assert_eq!(stem("rate"), "rate");
        assert_eq!(stem("cease"), "ceas");
        assert_eq!(stem("controll"), "control");
        assert_eq!(stem("roll"), "roll");
    }
}
