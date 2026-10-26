"""Gets answers from the project's Claude Code session.

claude - runs `claude -p` inside the project repo, so CLAUDE.md, skills,
         and project files are all in scope. Read-only tools only.
echo   - returns a canned answer (for plumbing tests without Claude)
"""
import asyncio
import os
import pathlib
import shlex

from compressor import select_brief

PROMPT = """You are my live meeting copilot for this project. I am in a meeting right now and someone just asked me a question. Give me something I can say out loud immediately.
Rules:
- First line starts with "SAY:" followed by 1-3 short, confident sentences I can speak verbatim.
- Then "DETAIL:" with up to 4 bullets of specifics (numbers, names, files, decisions, dates) I can use if they dig in.
- If you are not sure, say what you would verify and how, rather than guessing. Never invent numbers.
- Do not edit any files. Look things up in the repo only if the brief does not cover it.
- Keep the whole answer under 120 words.
- If a good answer needs facts that are not in the repo (vendor support matrices, OS or version compatibility, pricing, current docs), add a last line: RESEARCH_NEEDED: <what to research, under 15 words>

## Project brief
{brief}

## Recent meeting transcript (most recent last)
{context}

## Question I was asked
{question}
"""


def read_brief(project_dir, limit=12000):  # was 6000; a 1,500-word brief is ~9,400 chars (local change 2026-10-25)
    for name in ("meeting-brief.md", ".meeting-copilot/meeting-brief.md"):
        p = pathlib.Path(project_dir) / name
        if p.exists():
            return p.read_text()[:limit]
    return "(no meeting-brief.md yet; rely on CLAUDE.md and the repo)"


class EchoAnswerer:
    name = "echo"

    async def answer(self, question, context, project_dir, tools=None, timeout=None):
        await asyncio.sleep(0.2)
        return f"SAY: (test answer) You asked: {question}\nDETAIL:\n- context lines: {len(context.splitlines())}"


class ClaudeAnswerer:
    name = "claude"

    def __init__(self):
        self.model = os.environ.get("CLAUDE_MODEL", "")
        self.tools = os.environ.get("CLAUDE_ALLOWED_TOOLS", "Read,Grep,Glob")
        self.extra = shlex.split(os.environ.get("CLAUDE_EXTRA_ARGS", ""))
        self.timeout = float(os.environ.get("CLAUDE_TIMEOUT_S", "90"))

    async def answer(self, question, context, project_dir, tools=None, timeout=None):
        prompt = PROMPT.format(brief=select_brief(read_brief(project_dir), question, max_words=600),
                               context=context or "(none)",
                               question=question)
        args = ["claude", "-p", "--output-format", "text", "--allowedTools", tools or self.tools]
        if self.model:
            args += ["--model", self.model]
        args += self.extra
        proc = await asyncio.create_subprocess_exec(
            *args, cwd=project_dir,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(prompt.encode()), timeout or self.timeout)
        except asyncio.TimeoutError:
            proc.kill()
            return f"(timed out after {timeout or self.timeout:.0f}s)"
        if proc.returncode != 0:
            return f"(claude exited {proc.returncode}: {err.decode()[-400:].strip()})"
        return out.decode().strip()


def make_answerer():
    if os.environ.get("ANSWERER", "claude").lower() == "echo":
        return EchoAnswerer()
    return ClaudeAnswerer()
