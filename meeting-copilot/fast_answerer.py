"""Fast path: a warm, stripped-down Claude process that streams answers.

Why it's fast:
- The process stays running (stream-json input), so there's no CLI startup per question.
- No tools, no MCP servers, no skills: one model turn, no file reading.
- The brief is in the system prompt once (cached); each question sends only the
  cleaned question plus a few relevant transcript lines.
- Output streams token by token to the page.
- --bare is used when ANTHROPIC_API_KEY is set (it skips all auto-discovery, but
  doesn't use subscription login).

If the brief doesn't cover the question, the model replies with NEED_LOOKUP and
the server escalates to the full repo-aware session (answerer.py).
"""
import asyncio
import json
import logging
import os
import pathlib
import tempfile

from answerer import read_brief

log = logging.getLogger("copilot.fast")

SYSTEM = """You are a live meeting copilot. The user is in a meeting about the project described below, and someone just asked them a question. Every message you receive is one question plus a few recent transcript lines.

Answer instantly, from the brief and transcript only:
- First line: "SAY:" then 1-2 short, confident sentences the user can speak verbatim.
- Then "DETAIL:" with at most 3 short bullets (numbers, names, dates, decisions).
- Never invent facts. If the brief does not contain the answer, reply exactly:
  SAY: Good question — let me confirm and come back to you on that.
  NEED_LOOKUP: <what to look up in the repo, in under 15 words>
- No preamble, no markdown headings, under 70 words total.

# Project brief
{brief}
"""

USER = "Q: {question}\nRecent transcript:\n{context}"


def _flags(sys_file):
    model = os.environ.get("FAST_MODEL", "haiku")
    args = ["claude", "-p", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", model,
            "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
            "--no-session-persistence", "--append-system-prompt-file", str(sys_file)]
    if os.environ.get("FAST_EFFORT"):
        args += ["--effort", os.environ["FAST_EFFORT"]]
    if os.environ.get("ANTHROPIC_API_KEY") and os.environ.get("FAST_BARE", "1") == "1":
        args.insert(1, "--bare")
    return args


def _delta(evt):
    """Extract streamed text from one stream-json line, or None."""
    if evt.get("type") == "stream_event":
        d = evt.get("event", {}).get("delta", {})
        if d.get("type") == "text_delta":
            return d.get("text", "")
    return None


class WarmWorker:
    """One long-lived `claude -p --input-format stream-json` process."""

    def __init__(self, sys_file, cwd):
        self.sys_file, self.cwd = sys_file, cwd
        self.proc = None
        self.turns = 0
        self.lock = asyncio.Lock()

    async def start(self):
        args = _flags(self.sys_file)
        args[args.index("-p") + 1:args.index("-p") + 1] = ["--input-format", "stream-json"]
        self.proc = await asyncio.create_subprocess_exec(
            *args, cwd=self.cwd, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=4 * 1024 * 1024)
        log.info("warm worker started pid=%s", self.proc.pid)

    @property
    def alive(self):
        return self.proc is not None and self.proc.returncode is None

    async def ask(self, text, on_delta, timeout):
        async with self.lock:
            msg = {"type": "user", "message": {"role": "user",
                                               "content": [{"type": "text", "text": text}]}}
            self.proc.stdin.write((json.dumps(msg) + "\n").encode())
            await self.proc.stdin.drain()
            self.turns += 1
            parts = []

            async def read():
                while True:
                    line = await self.proc.stdout.readline()
                    if not line:
                        raise RuntimeError("warm worker exited")
                    try:
                        evt = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    d = _delta(evt)
                    if d:
                        parts.append(d)
                        await on_delta(d)
                    elif evt.get("type") == "result":
                        if evt.get("is_error"):
                            raise RuntimeError(str(evt.get("result"))[:300])
                        return evt.get("result") or "".join(parts)

            return await asyncio.wait_for(read(), timeout)

    async def close(self):
        if self.alive:
            try:
                self.proc.stdin.close()
                await asyncio.wait_for(self.proc.wait(), 3)
            except Exception:
                self.proc.kill()


class FastAnswerer:
    name = "fast"

    def __init__(self, project_dir):
        self.project_dir = project_dir
        self.timeout = float(os.environ.get("FAST_TIMEOUT_S", "30"))
        self.max_turns = int(os.environ.get("FAST_RECYCLE_AFTER", "8"))
        self.warm_enabled = os.environ.get("FAST_WARM", "1") == "1"
        # neutral working dir: keeps the repo's CLAUDE.md, .mcp.json and hooks out of the fast path
        self.cwd = pathlib.Path(tempfile.gettempdir()) / "meeting-copilot-fast"
        self.cwd.mkdir(exist_ok=True)
        self.sys_file = self.cwd / "system.md"
        self.brief_mtime = None
        self.worker = None
        self.spare = None

    def _write_system(self):
        brief = read_brief(self.project_dir)
        self.sys_file.write_text(SYSTEM.format(brief=brief))
        self.brief_mtime = self._brief_stamp()

    def _brief_stamp(self):
        p = pathlib.Path(self.project_dir) / "meeting-brief.md"
        return p.stat().st_mtime if p.exists() else None

    async def warm_up(self):
        """Start a worker ahead of time so the first question doesn't pay startup cost."""
        self._write_system()
        if self.warm_enabled:
            try:
                self.spare = WarmWorker(self.sys_file, self.cwd)
                await self.spare.start()
            except Exception:
                log.exception("could not start warm worker; using one-shot mode")
                self.warm_enabled = False

    async def _get_worker(self):
        if self._brief_stamp() != self.brief_mtime:  # brief edited: reload everything
            log.info("brief changed; recycling workers")
            for w in (self.worker, self.spare):
                if w:
                    await w.close()
            self.worker = self.spare = None
            self._write_system()
        if self.worker and (not self.worker.alive or self.worker.turns >= self.max_turns):
            asyncio.create_task(self.worker.close())
            self.worker = None
        if not self.worker:
            if self.spare and self.spare.alive:
                self.worker, self.spare = self.spare, None
            else:
                self.worker = WarmWorker(self.sys_file, self.cwd)
                await self.worker.start()
        if not self.spare:  # keep a replacement warming in the background
            self.spare = WarmWorker(self.sys_file, self.cwd)
            asyncio.create_task(self.spare.start())
        return self.worker

    async def answer(self, question, context, on_delta):
        text = USER.format(question=question, context=context or "(none)")
        if self.warm_enabled:
            try:
                worker = await self._get_worker()
                return await worker.ask(text, on_delta, self.timeout)
            except Exception as e:
                log.warning("warm path failed (%s); falling back to one-shot", e)
                if self.worker:
                    asyncio.create_task(self.worker.close())
                self.worker = None
        return await self._one_shot(text, on_delta)

    async def _one_shot(self, text, on_delta):
        if not self.sys_file.exists():
            self._write_system()
        proc = await asyncio.create_subprocess_exec(
            *_flags(self.sys_file), cwd=self.cwd, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=4 * 1024 * 1024)
        proc.stdin.write(text.encode())
        proc.stdin.close()
        parts, result = [], None

        async def read():
            nonlocal result
            async for line in proc.stdout:
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue
                d = _delta(evt)
                if d:
                    parts.append(d)
                    await on_delta(d)
                elif evt.get("type") == "result":
                    result = evt.get("result")
            await proc.wait()

        try:
            await asyncio.wait_for(read(), self.timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return f"(fast path timed out after {self.timeout:.0f}s)"
        if proc.returncode and not parts:
            err = (await proc.stderr.read()).decode()[-300:]
            return f"(fast path failed: {err.strip()})"
        return result or "".join(parts)


class EchoFast:
    """Test stand-in that streams a canned answer word by word."""
    name = "echo-fast"

    def __init__(self, project_dir):
        pass

    async def warm_up(self):
        pass

    async def answer(self, question, context, on_delta):
        if "lookup" in question.lower():
            text = "SAY: Good question — let me confirm and come back to you on that.\nNEED_LOOKUP: test escalation"
        else:
            text = f"SAY: (fast test) {question}\nDETAIL:\n- {len(context.splitlines())} context lines"
        for w in text.split(" "):
            await on_delta(w + " ")
            await asyncio.sleep(0.01)
        return text


def make_fast_answerer(project_dir):
    mode = os.environ.get("FAST_ANSWERER", "claude").lower()
    if mode == "off":
        return None
    if mode == "echo" or os.environ.get("ANSWERER", "").lower() == "echo":
        return EchoFast(project_dir)
    return FastAnswerer(project_dir)
