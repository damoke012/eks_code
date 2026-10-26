"""Shrinks what we send to Claude so answers start faster.

- clean_question:   strips filler, hedging and addressing from the spoken question
- compress_context: keeps only the transcript lines relevant to the question
- select_brief:     keeps only the brief sections relevant to the question (one-shot path)
"""
import re

STOP = set("""a an the and or but if so of to in on at for from by with about as is are was were be been
being do does did have has had i you he she it we they me us them my your our their this that these
those there here what which who whom whose when where why how can could would should will shall may
might must just really very also then than too not no yes ok okay right well like um uh hmm yeah
going get got gonna wanna kind sort thing things guys everyone everybody""".split())

FILLERS = [
    r"\bum+\b", r"\buh+\b", r"\berm+\b", r"\bhmm+\b", r"\byou know\b", r"\bi mean\b",
    r"\bbasically\b", r"\bactually\b", r"\bkind of\b", r"\bsort of\b", r"\bliterally\b",
    r"\blike,", r"\bso,", r"\bokay,", r"\bok,", r"\balright,", r"\bright,",
]
PREAMBLES = [
    r"^(hey|hi|so|okay|ok|and|alright|now)[, ]+",
    r"^(i was (just )?wondering|i'd like to know|i wanted to ask|quick question)( if)?[, ]*",
    r"^(if )?(can|could|would)? ?(you|we) (could |can |would )?(maybe |please |quickly |just )*(tell|give|share with|update) (us|me)( on| about)?[, ]*",
    r"^(do you (happen to )?know|any idea)[, ]*",
]
def words(text):
    return re.findall(r"[a-z0-9][a-z0-9'._-]*", text.lower())


def keywords(text):
    """Content words, lightly stemmed (first 6 chars) so 'migrating' ~ 'migration'."""
    return {w[:6] for w in words(text) if w not in STOP and len(w) > 2}


def clean_question(text, names=(), max_words=40):
    q = " " + text.strip() + " "
    for n in names:
        if n:
            q = re.sub(rf"(?i)\b(hey |hi |so )?{re.escape(n)}\b[,:]?", " ", q)
    for pat in FILLERS:
        q = re.sub(pat, " ", q, flags=re.I)
    q = re.sub(r"\b(\w+)( \1\b)+", r"\1", q, flags=re.I)  # "the the" -> "the" (Whisper stutters)
    q = re.sub(r"\s+", " ", q).strip(" ,.")
    q = re.sub(r"\s*,(\s*,)+", ",", q)  # ", ," left behind by removed fillers
    for _ in range(3):  # preambles can be stacked: "so, quick question, could you tell us..."
        before = q
        for pat in PREAMBLES:
            q = re.sub(pat, "", q, flags=re.I).strip(" ,")
        if q == before:
            break
    q = re.sub(r"\s+,", ",", q)
    w = q.split()
    if len(w) > max_words:  # long rambling question: the ask is usually at the end
        q = "… " + " ".join(w[-max_words:])
    if len(re.findall(r"\w+", q)) < 2:  # nothing meaningful left; keep the original
        return text.strip()
    return q[:1].upper() + q[1:]


def compress_context(segments, question, recent=3, extra=4, max_words=180):
    """segments: list of transcript strings, oldest first.
    Keep the last `recent` lines plus up to `extra` earlier lines that share keywords with the question."""
    segs = [s for s in segments if len(s.split()) >= 3]  # drop "yeah", "okay sure"
    if not segs:
        return ""
    tail = segs[-recent:]
    q = keywords(question)
    scored = []
    for i, s in enumerate(segs[:-recent] if len(segs) > recent else []):
        overlap = len(q & keywords(s))
        if overlap:
            scored.append((overlap, i, s))
    picked = sorted(sorted(scored, reverse=True)[:extra], key=lambda x: x[1])
    lines = [s for _, _, s in picked] + ([] if not picked else ["…"]) + tail
    out, count = [], 0
    for line in reversed(lines):  # keep the newest lines when trimming
        n = len(line.split())
        if count + n > max_words and out:
            break
        out.append(line)
        count += n
    return "\n".join(reversed(out))


def select_brief(brief, question, max_words=400, always=("status", "current")):
    """Split a markdown brief on headings and keep the sections most relevant to the question."""
    parts = re.split(r"(?m)^(?=#{1,3} )", brief)
    sections = [p.strip() for p in parts if p.strip()]
    if len(sections) <= 1:
        return " ".join(brief.split()[:max_words])
    q = keywords(question)
    ranked = []
    for i, sec in enumerate(sections):
        title = sec.splitlines()[0].lower()
        score = len(q & keywords(sec)) * 2 + len(q & keywords(title)) * 3
        if any(a in title for a in always):
            score += 2
        ranked.append((score, i, sec))
    chosen, count = [], 0
    for score, i, sec in sorted(ranked, reverse=True):
        n = len(sec.split())
        if score == 0 and chosen:
            break
        if count + n > max_words:
            if chosen:
                continue
            sec = " ".join(sec.split()[:max_words])
            n = max_words
        chosen.append((i, sec))
        count += n
    return "\n\n".join(s for _, s in sorted(chosen))


def word_count(*texts):
    return sum(len(t.split()) for t in texts if t)
