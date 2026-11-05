#!/usr/bin/env python3
"""Downloads the Project Gutenberg books that corpus/ vendors.

Each book is fetched as UTF-8 plain text, the Project Gutenberg header,
footer and licence are removed, and the remaining body is written to
corpus/<name>.txt with LF line endings.  Lines mentioning Project Gutenberg
are dropped as well, so the vendored files carry only the public-domain work
itself.

    python3 make_corpus.py            # fetch anything missing
    python3 make_corpus.py --force    # refetch everything

Running this is only needed to rebuild corpus/ from scratch; gen_tests.py
reads the vendored files and never touches the network.
"""
import argparse
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")

# (Project Gutenberg ebook number, vendored file name, title, author)
BOOKS = [
    (11, "alice", "Alice's Adventures in Wonderland", "Lewis Carroll"),
    (12, "looking-glass", "Through the Looking-Glass", "Lewis Carroll"),
    (16, "peter-pan", "Peter Pan", "J. M. Barrie"),
    (23, "douglass", "Narrative of the Life of Frederick Douglass", "Frederick Douglass"),
    (35, "time-machine", "The Time Machine", "H. G. Wells"),
    (36, "war-of-the-worlds", "The War of the Worlds", "H. G. Wells"),
    (43, "jekyll-hyde", "The Strange Case of Dr. Jekyll and Mr. Hyde", "Robert Louis Stevenson"),
    (45, "anne-of-green-gables", "Anne of Green Gables", "L. M. Montgomery"),
    (46, "christmas-carol", "A Christmas Carol", "Charles Dickens"),
    (55, "wizard-of-oz", "The Wonderful Wizard of Oz", "L. Frank Baum"),
    (74, "tom-sawyer", "The Adventures of Tom Sawyer", "Mark Twain"),
    (76, "huckleberry-finn", "Adventures of Huckleberry Finn", "Mark Twain"),
    (84, "frankenstein", "Frankenstein", "Mary Wollstonecraft Shelley"),
    (98, "two-cities", "A Tale of Two Cities", "Charles Dickens"),
    (120, "treasure-island", "Treasure Island", "Robert Louis Stevenson"),
    (158, "emma", "Emma", "Jane Austen"),
    (161, "sense-and-sensibility", "Sense and Sensibility", "Jane Austen"),
    (174, "dorian-gray", "The Picture of Dorian Gray", "Oscar Wilde"),
    (215, "call-of-the-wild", "The Call of the Wild", "Jack London"),
    (219, "heart-of-darkness", "Heart of Darkness", "Joseph Conrad"),
    (345, "dracula", "Dracula", "Bram Stoker"),
    (768, "wuthering-heights", "Wuthering Heights", "Emily Bronte"),
    (844, "being-earnest", "The Importance of Being Earnest", "Oscar Wilde"),
    (1080, "modest-proposal", "A Modest Proposal", "Jonathan Swift"),
    (1232, "the-prince", "The Prince", "Niccolo Machiavelli"),
    (1260, "jane-eyre", "Jane Eyre", "Charlotte Bronte"),
    (1342, "pride-and-prejudice", "Pride and Prejudice", "Jane Austen"),
    (1400, "great-expectations", "Great Expectations", "Charles Dickens"),
    (1661, "sherlock-holmes", "The Adventures of Sherlock Holmes", "Arthur Conan Doyle"),
    (1952, "yellow-wallpaper", "The Yellow Wallpaper", "Charlotte Perkins Gilman"),
    (2542, "dolls-house", "A Doll's House", "Henrik Ibsen"),
    (2591, "grimms-fairy-tales", "Grimms' Fairy Tales", "Jacob and Wilhelm Grimm"),
    (2814, "dubliners", "Dubliners", "James Joyce"),
    (1998, "zarathustra", "Thus Spake Zarathustra", "Friedrich Nietzsche"),
    (205, "walden", "Walden", "Henry David Thoreau"),
    (1727, "odyssey", "The Odyssey", "Homer"),
]

START = re.compile(r"^\*\*\*\s*START OF (THE|THIS) PROJECT GUTENBERG", re.I)
END = re.compile(r"^\*\*\*\s*END OF (THE|THIS) PROJECT GUTENBERG", re.I)
MENTION = re.compile(r"project\s+gutenberg|gutenberg\.org|pglaf|www\.gutenberg", re.I)


def fetch(num):
    url = f"https://www.gutenberg.org/cache/epub/{num}/pg{num}.txt"
    req = urllib.request.Request(url, headers={"User-Agent": "langbench-corpus/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def strip(text):
    """Return the body of a Project Gutenberg text file."""
    text = text.replace("\r\n", "\n").replace("\r", "\n").lstrip("﻿")
    lines = text.split("\n")
    first = last = None
    for i, line in enumerate(lines):
        if first is None and START.match(line):
            first = i + 1
        elif first is not None and END.match(line):
            last = i
            break
    if first is None:
        raise SystemExit("no start marker")
    if last is None:
        last = len(lines)
    body = [ln for ln in lines[first:last] if not MENTION.search(ln)]
    return "\n".join(body).strip("\n") + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    os.makedirs(CORPUS, exist_ok=True)
    for num, name, title, author in BOOKS:
        path = os.path.join(CORPUS, name + ".txt")
        if os.path.exists(path) and not args.force:
            continue
        body = strip(fetch(num))
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(body)
        print(f"{name}: {len(body)} bytes  ({title}, {author})", file=sys.stderr)


if __name__ == "__main__":
    main()
