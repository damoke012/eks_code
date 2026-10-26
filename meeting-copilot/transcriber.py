"""Speech-to-text backends.

whisper - faster-whisper running locally on the Codespace CPU (default; audio never leaves the Codespace)
mock    - no model; returns a placeholder describing the segment (for plumbing tests)
"""
import os
import re
import pathlib

SAMPLE_RATE = 16000


class MockTranscriber:
    name = "mock"

    def __init__(self):
        self.count = 0

    def transcribe(self, audio):
        self.count += 1
        return f"[mock segment {self.count}: {len(audio) / SAMPLE_RATE:.1f}s of audio]"


class WhisperTranscriber:
    name = "whisper"

    def __init__(self, model_size, glossary="", threads=None):
        from faster_whisper import WhisperModel  # imported lazily so mock mode needs no model

        threads = threads or int(os.environ.get("WHISPER_THREADS", os.cpu_count() or 4))
        self.model = WhisperModel(model_size, device="cpu", compute_type="int8",
                                  cpu_threads=threads)
        # Project vocabulary helps Whisper spell acronyms and product names correctly.
        self.prompt = glossary[:800] if glossary else None
        self.language = os.environ.get("WHISPER_LANGUAGE", "en")

    def transcribe(self, audio):
        # Local change 2026-10-25: vad_filter skips non-speech; temperature=0.0 stops the
        # retry-at-higher-temperature loop that took 52 s on laughter in a live meeting.
        segments, _ = self.model.transcribe(
            audio,
            language=self.language,
            beam_size=1,
            vad_filter=True,
            temperature=0.0,
            no_repeat_ngram_size=3,  # local change 2026-10-26: stops "yeah, yeah, yeah..." loops
            condition_on_previous_text=False,
            initial_prompt=self.prompt,
        )
        text = collapse_repeats(" ".join(s.text.strip() for s in segments).strip())
        return "" if is_hallucination(text) else text


# Phrases Whisper invents on noise or silence (learned from YouTube captions).
HALLUCINATIONS = {
    "thank you", "thank you very much", "thanks for watching", "thank you for watching",
    "thanks for watching!", "please subscribe", "you", "bye", "makes each other awesome",
    "subtitles by the amara.org community",
}


def collapse_repeats(text, keep=2):
    """Safety net for Whisper repetition loops: a word (or 2-3 word phrase) repeated more than
    `keep` times in a row is cut back to `keep` copies."""
    for n in (3, 2, 1):
        text = re.sub(r"(?i)\b((?:[\w']+[,.!?]?\s+){%d})(?:\1){%d,}" % (n, keep), r"\1" * keep, text + " ").strip()
    return text


def is_hallucination(text):
    t = text.lower().strip(" .!?,")
    return not t or t in HALLUCINATIONS


def load_glossary(project_dir):
    path = pathlib.Path(project_dir) / ".meeting-copilot" / "glossary.txt"
    if path.exists():
        words = [w.strip() for w in path.read_text().splitlines() if w.strip()]
        return "Terms used in this meeting: " + ", ".join(words) + "."
    return ""


def make_transcriber(project_dir):
    backend = os.environ.get("TRANSCRIBER", "whisper").lower()
    if backend == "mock":
        return MockTranscriber()
    model = os.environ.get("WHISPER_MODEL", "small.en")
    return WhisperTranscriber(model, load_glossary(project_dir))


def make_refiner(project_dir):
    """Local change 2026-10-26: second-pass model that re-transcribes the other people's lines
    in the background and corrects them in place (speed first, accuracy a few seconds later).
    REFINE_MODEL=off disables it."""
    if os.environ.get("TRANSCRIBER", "whisper").lower() == "mock":
        return None
    model = os.environ.get("REFINE_MODEL", "large-v3-turbo")
    if model.lower() in ("", "off", "none"):
        return None
    t = WhisperTranscriber(model, load_glossary(project_dir),
                           threads=int(os.environ.get("REFINE_THREADS", "10")))
    t.name = "refine:" + model
    return t
