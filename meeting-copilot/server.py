"""Meeting Copilot server.

Browser recorder page -> /ws/audio (16 kHz int16 PCM) -> segmenter -> transcriber
-> question detector -> Claude (in the project repo) -> answers pushed to /ws/events.
"""
import asyncio
import datetime
import difflib
import itertools
import json
import logging
import os
import pathlib
import re
import time

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from answerer import make_answerer
from compressor import clean_question, compress_context, word_count
from detector import QuestionDetector
from fast_answerer import make_fast_answerer
from segmenter import Segmenter
from transcriber import make_refiner, make_transcriber
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("copilot")

BASE = pathlib.Path(__file__).resolve().parent
PROJECT_DIR = os.environ.get("PROJECT_DIR", str(BASE.parent))
CONTEXT_SEGMENTS = int(os.environ.get("CONTEXT_SEGMENTS", "25"))
DATA_DIR = pathlib.Path(PROJECT_DIR) / ".meeting-copilot" / "transcripts"
MY_LABEL = os.environ.get("MY_LABEL", "Dare")  # how the user's mic is labelled in the transcript

# Local change 2026-10-26: the mic hears the speakers. With speakers instead of headphones
# every meeting line is transcribed TWICE -- once from the meeting tab as "Them", then again
# ~3s later from the mic under the user's own name. Measured on meeting_2026-10-26_1833:
# 151 "Dare" lines against 106 "Them", and most of the Dare lines were echo. It also doubles
# the work for the answerer and puts words in the user's mouth that they never said.
# A mic line that repeats a recent meeting line is echo, so drop it.
# ECHO_RATIO=0 disables this entirely.
ECHO_WINDOW_S = float(os.environ.get("ECHO_WINDOW_S", "12"))
ECHO_RATIO = float(os.environ.get("ECHO_RATIO", "0.60"))
# 0.60 chosen by replaying meeting_2026-10-26_1833 through this function:
#   0.80 -> 53 of 151 suppressed, 0.70 -> 57, 0.60 -> 63, 0.55 -> 64.
# Every line 0.60 caught that 0.80 missed was read and confirmed to be echo
# ("I totally used the root credentials", the other side's sign-off, and so on).
# Below 0.60 the return collapses, so that is where the evidence stops.


def norm_text(s):
    """Lowercase, letters and digits only -- so punctuation and filler don't defeat the match."""
    return re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()

app = FastAPI(title="Meeting Copilot")
app.mount("/static", StaticFiles(directory=BASE / "static"), name="static")


class Meeting:
    def __init__(self):
        self.transcriber = None  # loaded on startup
        self.answerer = make_answerer()                  # deep path: full repo-aware session
        self.fast = make_fast_answerer(PROJECT_DIR)      # fast path: warm, tool-less, streaming
        self.auto_deep = os.environ.get("AUTO_DEEP", "1") == "1"
        self.questions = {}
        self.detector = QuestionDetector(
            names=os.environ.get("MY_NAMES", "dare").split(","),
            mode=os.environ.get("DETECT_MODE", "addressed"),
            cooldown_s=float(os.environ.get("DETECT_COOLDOWN_S", "8")),
        )
        self.segments = []  # list of (timestamp, text)
        self.viewers = set()
        self.stt_queue = asyncio.Queue()
        self.ids = itertools.count(1)
        self.answer_lock = asyncio.Semaphore(int(os.environ.get("MAX_PARALLEL_ANSWERS", "2")))
        self.log_path = None
        self.recording = False
        self.active_audio = 0  # open /ws/audio sockets (meeting tab and/or mic)
        # Local change 2026-10-26: second-pass corrections + silent-meeting warning
        self.refiner = None                    # loaded on startup (REFINE_MODEL)
        self.refine_queue = asyncio.Queue()
        self.refine_min_s = float(os.environ.get("REFINE_MIN_S", "1.5"))
        self.refine_max_backlog = int(os.environ.get("REFINE_MAX_BACKLOG", "3"))
        self.sids = itertools.count(1)
        self.seg_info = {}                     # sid -> {"i", "speaker", "source", "asked", "entry"}
        self.log_entries = []                  # str lines or dicts for transcript lines
        self.echo_dropped = 0                  # mic lines suppressed as echo of the meeting
        self.connected = {"them": 0, "me": 0}
        self.last_speech = {}                  # src -> time a speech segment last arrived
        self.connected_at = {}
        self.last_warn = 0.0

    # ---- broadcasting -------------------------------------------------
    async def broadcast(self, msg):
        dead = []
        for ws in self.viewers:
            try:
                await ws.send_text(json.dumps(msg))
            except Exception:
                dead.append(ws)
        for ws in dead:
            self.viewers.discard(ws)

    def status(self):
        return {
            "type": "status",
            "recording": self.recording,
            "mode": self.detector.mode,
            "transcriber": getattr(self.transcriber, "name", "loading"),
            "answerer": (self.fast.name + "+" if self.fast else "") + self.answerer.name,
            "project": pathlib.Path(PROJECT_DIR).name,
            "transcript": self.log_path.name if self.log_path else None,
            "echo_dropped": self.echo_dropped,
        }

    # ---- transcript ---------------------------------------------------
    def start_log(self):
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y-%m-%d_%H%M")
        self.log_path = DATA_DIR / f"meeting_{stamp}.md"
        self.log_entries = [f"# Meeting transcript {stamp}\n"]
        self.write_log()

    def write_log(self):
        """Rewrite the whole file so corrected lines replace their first draft."""
        if not self.log_path:
            return
        out = []
        for e in self.log_entries:
            if isinstance(e, dict):
                mark = " _(corrected)_" if e.get("fixed") else ""
                out.append(f"- [{e['clock']}] **{e['speaker']}:** {e['text']}{mark}")
            else:
                out.append(e)
        self.log_path.write_text("\n".join(out) + "\n")

    def append_log(self, line):
        if self.log_path:
            self.log_entries.append(line)
            self.write_log()

    def context(self):
        lines = [t for _, t in self.segments[-CONTEXT_SEGMENTS:]]
        return "\n".join(lines)

    def is_echo_of_meeting(self, text, ts):
        """True when a mic line just repeats something the meeting tab already said.

        Only ever called for the user's own mic. Walks back through recent segments,
        newest first, and stops at the window edge -- so it is O(a few) per segment.
        """
        if ECHO_RATIO <= 0:
            return False
        a = norm_text(text)
        if not a:
            return False
        for t0, line in reversed(self.segments):
            if ts - t0 > ECHO_WINDOW_S:
                break
            if not line.startswith("Them: "):
                continue
            b = norm_text(line[len("Them: "):])
            if not b:
                continue
            if a == b:
                return True                      # catches short echoes like "um" and "okay"
            if len(a) < 8:
                continue                         # below that, only an exact match is safe
            if difflib.SequenceMatcher(None, a, b).ratio() >= ECHO_RATIO:
                return True
            if len(a) >= 16 and a in b:
                return True                      # mic caught only part of a longer line
        return False

    async def add_segment(self, text, source="them", audio=None):
        # Local change 2026-10-25: speaker comes from the audio source, not the voice.
        # "me" = the user's microphone (labelled MY_LABEL), anything else = other participants.
        text = text.strip()
        if not text:
            return
        ts = time.time()
        # Local change 2026-10-26: if the meeting stream is silent (wrong tab / desktop app /
        # speakers into the mic), the mic is hearing EVERYONE: label it "Mic" and answer from it.
        mic_is_meeting = source == "me" and self.meeting_stream_silent()
        if source == "me" and not mic_is_meeting and self.is_echo_of_meeting(text, ts):
            self.echo_dropped += 1
            log.debug("echo suppressed: %s", text[:60])
            return
        speaker = ("Mic" if mic_is_meeting else MY_LABEL) if source == "me" else "Them"
        sid = next(self.sids)
        self.segments.append((ts, f"{speaker}: {text}"))
        clock = datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S")
        entry = {"clock": clock, "speaker": speaker, "text": text}
        if self.log_path:
            self.log_entries.append(entry)
            self.write_log()
        await self.broadcast({"type": "transcript", "sid": sid, "text": text, "time": clock,
                              "source": source, "speaker": speaker, "me": source == "me"})
        answerable = source != "me" or mic_is_meeting  # never answer the user's own speech
        asked = answerable and self.detector.check(text)
        if asked:
            asyncio.create_task(self.ask(text, auto=True))
        self.seg_info[sid] = {"i": len(self.segments) - 1, "speaker": speaker, "source": source,
                              "asked": asked, "entry": entry, "ts": ts}
        # second pass: only other people's lines, only ones long enough to matter
        if (self.refiner and audio is not None and answerable
                and len(audio) / 16000 >= self.refine_min_s):
            await self.refine_queue.put((sid, audio))

    def meeting_stream_silent(self):
        """True when no meeting stream is connected, or it has carried no speech for
        SILENT_WARN_S seconds. ANSWER_MIC=always|never overrides."""
        mode = os.environ.get("ANSWER_MIC", "auto").lower()
        if mode in ("always", "never"):
            return mode == "always"
        if not self.connected.get("them"):
            return True
        if "them" not in self.last_speech:  # meeting stream has never carried speech: answer from the mic now
            return True
        since = max(self.last_speech.get("them", 0), self.connected_at.get("them", 0))
        return time.time() - since > float(os.environ.get("SILENT_WARN_S", "20"))

    async def refine_worker(self):
        """Re-transcribe with the stronger model and correct the line in place."""
        while True:
            sid, audio = await self.refine_queue.get()
            try:
                if self.refine_queue.qsize() >= self.refine_max_backlog:
                    continue  # fallen behind: skip older lines so corrections stay current
                info = self.seg_info.get(sid)
                if not info:
                    continue
                started = time.time()
                text = (await asyncio.to_thread(self.refiner.transcribe, audio)).strip()
                log.info("refine %.1fs audio -> %.2fs: %s", len(audio) / 16000,
                         time.time() - started, text[:80])
                old = info["entry"]["text"]
                norm = lambda t: " ".join(t.lower().replace(",", " ").replace(".", " ").split())
                if not text or norm(text) == norm(old):
                    continue
                info["entry"]["text"] = text
                info["entry"]["fixed"] = True
                self.segments[info["i"]] = (info["ts"], f"{info['speaker']}: {text}")
                self.write_log()
                await self.broadcast({"type": "transcript_fix", "sid": sid, "text": text})
                # a question the fast pass garbled can still be caught on the corrected text
                if not info["asked"] and (info["source"] != "me" or info["speaker"] == "Mic") \
                        and self.detector.check(text):
                    info["asked"] = True
                    asyncio.create_task(self.ask(text, auto=True))
            except Exception:
                log.exception("refine failed")
            finally:
                self.refine_queue.task_done()

    # ---- answering ----------------------------------------------------
    async def ask(self, question, auto=False):
        qid = next(self.ids)
        names = self.detector.names
        clean = clean_question(question, names)
        recent = [t for _, t in self.segments[-CONTEXT_SEGMENTS:]]
        context = compress_context(recent, clean)
        self.questions[qid] = (clean, context)
        before = word_count(question, *recent)
        after = word_count(clean, context)
        await self.broadcast({"type": "question", "id": qid, "text": question, "clean": clean,
                              "auto": auto, "words": [before, after]})
        self.append_log(f"\n**Q{qid}:** {question}\n(compressed: {clean})")
        if not self.fast:
            await self.deep(qid)
            return
        started = time.time()
        first = None

        async def on_delta(chunk):
            nonlocal first
            if first is None:
                first = int((time.time() - started) * 1000)
            await self.broadcast({"type": "answer_delta", "id": qid, "text": chunk})

        try:
            answer = await self.fast.answer(clean, context, on_delta)
        except Exception as e:
            log.exception("fast answer failed")
            answer = f"(fast path error: {e}) NEED_LOOKUP: {clean}"
        ms = int((time.time() - started) * 1000)
        self.append_log(f"**A{qid} fast** ({ms} ms, first token {first} ms):\n{answer}\n")
        await self.broadcast({"type": "answer", "id": qid, "text": answer, "ms": ms,
                              "first_ms": first, "stage": "fast"})
        if "NEED_LOOKUP" in answer and self.auto_deep:
            hint = answer.split("NEED_LOOKUP:", 1)[-1].strip()
            await self.deep(qid, hint)

    async def deep(self, qid, hint=""):
        """Full repo-aware answer (slower). Runs on escalation or when you click Dig deeper."""
        if qid not in self.questions:
            return
        clean, context = self.questions[qid]
        await self.broadcast({"type": "deep_start", "id": qid})
        started = time.time()
        q = clean + (f"\n(Look up: {hint})" if hint else "")
        async with self.answer_lock:
            try:
                answer = await self.answerer.answer(q, context, PROJECT_DIR)
            except Exception as e:  # never let one failure kill the meeting
                log.exception("deep answer failed")
                answer = f"(error: {e})"
        ms = int((time.time() - started) * 1000)
        self.append_log(f"**A{qid} deep** ({ms} ms):\n{answer}\n")
        await self.broadcast({"type": "answer", "id": qid, "text": answer, "ms": ms, "stage": "deep"})

    async def more(self, qid, stage, extra=""):
        """Local change 2026-10-25. stage="refine": re-answer with context the user typed
        (repo, read-only). stage="research": also allow web search, longer timeout."""
        if qid not in self.questions:
            return
        clean, context = self.questions[qid]
        await self.broadcast({"type": "more_start", "id": qid, "stage": stage})
        started = time.time()
        q = clean
        if extra:
            q += f"\n(Extra context from me, use it to make the answer specific: {extra})"
        if stage == "research":
            q += ("\n(Go beyond the brief: check the repo thoroughly and, where it helps, vendor "
                  "documentation on the web. Cite the source for each fact.)")
            tools = os.environ.get("RESEARCH_ALLOWED_TOOLS", "Read,Grep,Glob,WebSearch,WebFetch")
            timeout = float(os.environ.get("RESEARCH_TIMEOUT_S", "240"))
        else:
            tools, timeout = None, None
        async with self.answer_lock:
            try:
                answer = await self.answerer.answer(q, context, PROJECT_DIR, tools=tools, timeout=timeout)
            except Exception as e:
                log.exception("%s answer failed", stage)
                answer = f"(error: {e})"
        ms = int((time.time() - started) * 1000)
        self.append_log(f"**A{qid} {stage}** ({ms} ms){' — context: ' + extra if extra else ''}:\n{answer}\n")
        await self.broadcast({"type": "answer", "id": qid, "text": answer, "ms": ms, "stage": stage})

    # ---- speech-to-text worker ------------------------------------------
    async def stt_worker(self):
        while True:
            audio, src = await self.stt_queue.get()
            try:
                started = time.time()
                text = await asyncio.to_thread(self.transcriber.transcribe, audio)
                log.info("stt [%s] %.1fs audio -> %.2fs: %s", src, len(audio) / 16000,
                         time.time() - started, text[:80])
                await self.add_segment(text, source=src, audio=audio)
            except Exception:
                log.exception("transcription failed")
            finally:
                self.stt_queue.task_done()


meeting = Meeting()


@app.on_event("startup")
async def startup():
    log.info("project dir: %s", PROJECT_DIR)
    log.info("loading transcriber (first run downloads the Whisper model)...")
    meeting.transcriber = await asyncio.to_thread(make_transcriber, PROJECT_DIR)
    log.info("transcriber ready: %s", meeting.transcriber.name)
    if meeting.fast:
        await meeting.fast.warm_up()
        log.info("fast path ready: %s", meeting.fast.name)
    asyncio.create_task(meeting.stt_worker())
    try:  # local change 2026-10-26: background second pass (first run downloads the model)
        meeting.refiner = await asyncio.to_thread(make_refiner, PROJECT_DIR)
        if meeting.refiner:
            asyncio.create_task(meeting.refine_worker())
            log.info("refiner ready: %s", meeting.refiner.name)
    except Exception:
        log.exception("refiner failed to load; continuing with the fast pass only")


@app.get("/")
async def index():
    return FileResponse(BASE / "static" / "index.html")


@app.get("/api/health")
async def health():
    return JSONResponse({**meeting.status(), "segments": len(meeting.segments),
                         "queue": meeting.stt_queue.qsize()})


class Inject(BaseModel):
    text: str


@app.post("/api/inject")
async def inject(body: Inject):
    """Testing hook: treat text as if it had been heard in the meeting."""
    await meeting.add_segment(body.text, source="inject")
    return {"ok": True}


class Ask(BaseModel):
    text: str = ""


@app.post("/api/ask")
async def ask(body: Ask):
    q = body.text.strip() or " ".join(t for _, t in meeting.segments[-2:])
    if not q:
        return {"ok": False, "error": "nothing to ask yet"}
    asyncio.create_task(meeting.ask(q))
    return {"ok": True, "question": q}


@app.websocket("/ws/events")
async def events(ws: WebSocket):
    await ws.accept()
    meeting.viewers.add(ws)
    await ws.send_text(json.dumps(meeting.status()))
    for ts, text in meeting.segments[-CONTEXT_SEGMENTS:]:
        clock = datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S")
        await ws.send_text(json.dumps({"type": "transcript", "text": text, "time": clock}))
    try:
        while True:
            msg = json.loads(await ws.receive_text())
            if msg.get("type") == "ask":
                q = (msg.get("text") or "").strip() or " ".join(t for _, t in meeting.segments[-2:])
                if q:
                    asyncio.create_task(meeting.ask(q))
            elif msg.get("type") == "deeper":
                asyncio.create_task(meeting.deep(int(msg.get("id", 0))))
            elif msg.get("type") in ("refine", "research"):
                asyncio.create_task(meeting.more(int(msg.get("id", 0)), msg["type"],
                                                 (msg.get("text") or "").strip()[:500]))
            elif msg.get("type") == "mode":
                meeting.detector.set_mode(msg.get("mode", ""))
                await meeting.broadcast(meeting.status())
    except WebSocketDisconnect:
        pass
    finally:
        meeting.viewers.discard(ws)


@app.websocket("/ws/audio")
async def audio(ws: WebSocket):
    await ws.accept()
    # Local change 2026-10-25: one socket per source (?src=them for the meeting, ?src=me for
    # the user's mic). Both share one transcript file; recording ends when the last one closes.
    src = "me" if ws.query_params.get("src") == "me" else "them"
    seg = Segmenter(silence_ms=int(os.environ.get("SILENCE_MS", "800")))
    if meeting.active_audio == 0:
        meeting.start_log()
        log.info("recording started -> %s", meeting.log_path)
    meeting.active_audio += 1
    meeting.connected[src] += 1
    meeting.connected_at[src] = time.time()
    if src == "them":
        meeting.last_speech.pop("them", None)  # new capture: prove the meeting stream works again
    meeting.recording = True
    log.info("audio source connected: %s", src)
    await meeting.broadcast(meeting.status())
    warn_after = float(os.environ.get("SILENT_WARN_S", "20"))
    try:
        while True:
            data = await ws.receive_bytes()
            for chunk in seg.feed(data):
                now = time.time()
                meeting.last_speech[src] = now
                await meeting.stt_queue.put((chunk, src))
                # Local change 2026-10-26: the mic hears speech but the meeting stream has been
                # silent -> the wrong tab was shared, tab audio is off, or the call plays
                # through speakers into the mic (everything would be labelled as the user).
                them_since = max(meeting.last_speech.get("them", 0), meeting.connected_at.get("them", now))
                if (src == "me" and meeting.connected["them"] and now - them_since > warn_after
                        and now - meeting.last_warn > 30):
                    meeting.last_warn = now
                    log.warning("meeting stream silent for %.0fs while mic hears speech", now - them_since)
                    await meeting.broadcast({"type": "warn", "text":
                        "The meeting stream is silent, so your mic is hearing everyone. Lines are now "
                        "labelled 'Mic' and questions are answered from them. For proper You/Them labels: "
                        "Stop, Capture meeting tab, pick the meeting's TAB, switch on 'Share tab audio', "
                        "wear headphones."})
    except WebSocketDisconnect:
        pass
    finally:
        for chunk in seg.flush():
            await meeting.stt_queue.put((chunk, src))
        meeting.connected[src] -= 1
        meeting.active_audio -= 1
        meeting.recording = meeting.active_audio > 0
        if not meeting.recording:
            log.info("recording stopped -> %s", meeting.log_path)
        await meeting.broadcast(meeting.status())
