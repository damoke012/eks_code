"""End-to-end test client for Meeting Copilot.

Streams a WAV file (or a synthetic tone pattern) to /ws/audio like the browser does,
optionally injects a question, and prints every event the server sends back.

  python3 tools/test_client.py --wav sample.wav --speed 4
  python3 tools/test_client.py --synthetic --inject "Dare, what's the status of the migration?"
"""
import argparse
import asyncio
import json
import urllib.request
import wave

import numpy as np
import websockets

SR = 16000


def load_wav(path):
    with wave.open(path, "rb") as w:
        sr, ch, width = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if width != 2:
        raise SystemExit("WAV must be 16-bit PCM")
    a = np.frombuffer(raw, dtype=np.int16).astype(np.float32)
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    if sr != SR:  # linear resample
        n = int(len(a) * SR / sr)
        a = np.interp(np.linspace(0, len(a) - 1, n), np.arange(len(a)), a)
    return a.astype(np.int16)


def synthetic():
    """Three 'utterances' of voice-like noise separated by silence."""
    rng = np.random.default_rng(0)
    parts = []
    for dur in (1.5, 2.5, 1.2):
        t = np.arange(int(dur * SR)) / SR
        voice = 0.2 * np.sin(2 * np.pi * 180 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 3 * t))
        voice += 0.03 * rng.standard_normal(len(t))
        parts += [voice, np.zeros(int(1.2 * SR))]
    return (np.concatenate(parts) * 32767).astype(np.int16)


async def listen(url, seconds, done):
    async with websockets.connect(url + "/ws/events") as ws:
        try:
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=seconds))
                print("EVENT", json.dumps(msg)[:300], flush=True)
                if msg.get("type") == "answer":
                    done.append(msg)
        except asyncio.TimeoutError:
            pass


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://127.0.0.1:8765")
    ap.add_argument("--wav")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--speed", type=float, default=1.0, help="1 = real time")
    ap.add_argument("--inject", help="text to inject as if it was heard")
    ap.add_argument("--wait", type=float, default=30, help="seconds of quiet before exiting")
    a = ap.parse_args()

    answers = []
    listener = asyncio.create_task(listen(a.url, a.wait, answers))
    await asyncio.sleep(0.5)

    if a.wav or a.synthetic:
        pcm = load_wav(a.wav) if a.wav else synthetic()
        async with websockets.connect(a.url + "/ws/audio") as ws:
            step = 1600  # 100 ms, same as the browser
            for i in range(0, len(pcm), step):
                await ws.send(pcm[i:i + step].tobytes())
                await asyncio.sleep(0.1 / a.speed)
        print(f"sent {len(pcm) / SR:.1f}s of audio", flush=True)

    if a.inject:
        http = a.url.replace("ws://", "http://").replace("wss://", "https://")
        req = urllib.request.Request(http + "/api/inject", data=json.dumps({"text": a.inject}).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req).read()
        print("injected:", a.inject, flush=True)

    await listener
    print(f"\nRESULT: {len(answers)} answer(s) received")
    raise SystemExit(0 if (answers or not a.inject) else 1)


if __name__ == "__main__":
    asyncio.run(main())
