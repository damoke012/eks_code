"""Decides which transcript segments are questions worth answering.

Modes:
  addressed - a question that mentions you by name, or comes right after your name (default)
  all       - any question
  manual    - never auto-answer; use the Ask button or type a question
"""
import re
import time

QUESTION_STARTERS = {
    "what", "why", "how", "when", "where", "who", "which", "whose",
    "can", "could", "would", "should", "will", "is", "are", "was", "were",
    "do", "does", "did", "have", "has", "any", "anything",
}
ASK_PHRASES = (
    "walk us through", "tell us", "can you explain", "explain", "talk about",
    "give us", "what's the status", "status on", "update on", "thoughts on",
    "remind us", "what about", "tell me",
)
# Spoken questions often open with filler ("okay, so what...", "and how...").
# Skip these before checking for a question word. (Local change, 2026-10-25.)
LEAD_FILLERS = {
    "okay", "ok", "so", "and", "but", "well", "alright", "right", "um", "uh",
    "hmm", "yeah", "now", "then", "hey", "hi", "also", "just", "like", "actually",
}


class QuestionDetector:
    def __init__(self, names, mode="addressed", cooldown_s=8.0, min_words=4):
        self.names = [n.strip().lower() for n in names if n.strip()]
        self.mode = mode
        self.cooldown_s = cooldown_s
        self.min_words = min_words
        self._addressed_until = 0.0  # name heard recently -> following question counts
        self._last_fire = 0.0

    def set_mode(self, mode):
        if mode in ("addressed", "all", "manual"):
            self.mode = mode

    def mentions_me(self, text):
        t = text.lower()
        return any(re.search(rf"\b{re.escape(n)}\b", t) for n in self.names)

    @staticmethod
    def looks_like_question(text):
        t = text.strip().lower()
        if "?" in t:
            return True
        words = re.findall(r"[a-z']+", t)
        if not words:
            return False
        while len(words) > 1 and words[0] in LEAD_FILLERS:
            words = words[1:]
        if words[0] in QUESTION_STARTERS:
            return True
        return any(p in t for p in ASK_PHRASES)

    def check(self, text, now=None):
        now = now or time.time()
        addressed_now = self.mentions_me(text)
        if addressed_now:
            self._addressed_until = now + 15.0

        if self.mode == "manual":
            return False
        if len(text.split()) < self.min_words:
            return False
        if not self.looks_like_question(text):
            return False
        if self.mode == "addressed" and not (addressed_now or now < self._addressed_until):
            return False
        if now - self._last_fire < self.cooldown_s:
            return False
        self._last_fire = now
        self._addressed_until = 0.0  # the follow-up window answers one question only
        return True
