#!/usr/bin/env python3
"""Score a hypothesis against a DiPCo reference.

Three metrics, because one number hides the thing we care about:

  WER         standard Levenshtein over all tokens, including the disfluencies the
              reference is full of ("ummm", "uhhh", "hmmm"). A recogniser can look
              respectable here while dropping most of the actual sentences, because
              fillers are cheap to hit and numerous.
  content     recall over reference content words: everything that is not a filler and
              not a function word. This is the "misses obvious words" metric — it counts
              only substitutions and deletions against a real reference token, so it
              cannot be gamed by hallucinating extra words.
  neg/num     the high-stakes subset: negations and numbers. Small enough to vanish
              inside WER, and the tokens where an error changes what a caption reader
              believes was said.

Usage: python3 -I Scripts/dipco-recall-score.py <reference.txt> <hypothesis.txt> <tag>

Prints a human-readable line and a machine-readable POOL line, so a shell loop can score a
directory of hypotheses and pool the windows. `Metrics/` in the package scores the fixture set and
is what the test suite covers; this one exists because the metrics that matter on DiPCo — how much
of the reference survived, and how the negations and numbers came out — are not the ones the
fixture set needed, and because it has to run over hypotheses produced by engines and corpora that
the package never loads.
"""
import re
import sys

FILLERS = {"ummm", "uhhh", "ahhh", "hmmm", "umm", "uhh", "ahh", "hmm", "uh", "um", "ah",
           "erm", "mmm", "hm", "mm", "huh", "uhhuh", "mmhmm", "uhhuhh", "like", "yeah",
           "okay", "ok", "oh", "well", "right", "so", "and", "but", "the", "a", "an"}

STOPWORDS = {
    "i", "me", "my", "myself", "we", "our", "ours", "ourselves", "you", "your", "yours",
    "he", "him", "his", "she", "her", "hers", "it", "its", "they", "them", "their",
    "what", "which", "who", "whom", "this", "that", "these", "those", "am", "is", "are",
    "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did",
    "will", "would", "shall", "should", "can", "could", "may", "might", "must", "of",
    "at", "by", "for", "with", "about", "against", "between", "into", "through",
    "during", "before", "after", "above", "below", "to", "from", "up", "down", "in",
    "out", "on", "off", "over", "under", "again", "further", "then", "once", "here",
    "there", "when", "where", "why", "how", "all", "any", "both", "each", "few",
    "more", "most", "other", "some", "such", "only", "own", "same", "than", "too",
    "very", "just", "now", "also", "get", "got", "go", "going", "know", "think",
    "want", "really", "one", "two", "three", "because", "if", "or", "as", "if", "not",
}

NEGATIONS = {"no", "not", "dont", "doesnt", "didnt", "wont", "cant", "cannot", "isnt",
             "arent", "wasnt", "werent", "never", "nothing", "nobody", "none", "nor",
             "without", "neither", "havent", "hasnt", "hadnt", "wouldnt", "couldnt",
             "shouldnt", "aint"}

NUMBER_WORDS = {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
                "forty", "fourty", "fifty", "sixty", "seventy", "eighty", "ninety",
                "hundred", "thousand", "million", "billion", "first", "second", "third",
                "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                "half", "quarter", "dozen", "couple", "pair"}
DIGITS = re.compile(r"^\$?\d[\d,.]*%?$")


def words(text):
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^\w\s'$%.]", " ", text)
    return [w.strip("'") for w in text.split() if w.strip("'")]


def edit_ops(ref, hyp):
    """Levenshtein backtrace -> list of (op, ref_word, hyp_word), op in ok/sub/del/ins."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        ri = ref[i - 1]
        row, prev = d[i], d[i - 1]
        for j in range(1, m + 1):
            cost = 0 if ri == hyp[j - 1] else 1
            row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
    ops = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + (0 if ref[i - 1] == hyp[j - 1] else 1):
            ops.append(("ok" if ref[i - 1] == hyp[j - 1] else "sub", ref[i - 1], hyp[j - 1]))
            i -= 1
            j -= 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", ref[i - 1], None))
            i -= 1
        else:
            ops.append(("ins", None, hyp[j - 1]))
            j -= 1
    ops.reverse()
    return ops


def is_neg_or_num(w):
    return w in NEGATIONS or w in NUMBER_WORDS or bool(DIGITS.match(w))


def is_content(w):
    return w not in FILLERS and w not in STOPWORDS and not is_neg_or_num(w)


def main():
    ref = words(open(sys.argv[1]).read())
    hyp = words(open(sys.argv[2]).read())
    tag = sys.argv[3] if len(sys.argv) > 3 else sys.argv[2]
    ops = edit_ops(ref, hyp)

    sub = sum(1 for o in ops if o[0] == "sub")
    dele = sum(1 for o in ops if o[0] == "del")
    ins = sum(1 for o in ops if o[0] == "ins")
    wer = (sub + dele + ins) / len(ref)

    def recall(pred):
        refd = [o for o in ops if o[1] and pred(o[1])]
        hit = sum(1 for o in refd if o[0] == "ok")
        return (hit / len(refd) if refd else float("nan")), hit, len(refd)

    content, chit, ctot = recall(is_content)
    negnum, nhit, ntot = recall(is_neg_or_num)

    print("%-20s ref=%4d hyp=%4d  WER=%5.1f%% S%3d D%3d I%3d  content=%5.1f%% (%d/%d)  "
          "neg+num=%5.1f%% (%d/%d)"
          % (tag, len(ref), len(hyp), wer * 100, sub, dele, ins, content * 100, chit, ctot,
             negnum * 100, nhit, ntot))
    print("POOL\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d"
          % (tag, len(ref), sub, dele, ins, chit, ctot, nhit, ntot))


if __name__ == "__main__":
    main()
