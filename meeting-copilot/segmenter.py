"""Energy-based voice-activity segmenter.

Takes a stream of 16 kHz mono int16 PCM and emits speech segments
(float32 numpy arrays) when the speaker pauses, or when a segment
gets too long.
"""
import numpy as np

SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME = SAMPLE_RATE * FRAME_MS // 1000  # 480 samples


class Segmenter:
    def __init__(self, silence_ms=800, max_segment_s=20.0, min_speech_s=0.5,
                 min_threshold=0.006):
        self.silence_frames = silence_ms // FRAME_MS
        self.max_samples = int(max_segment_s * SAMPLE_RATE)
        self.min_speech_frames = int(min_speech_s * 1000) // FRAME_MS
        self.min_threshold = min_threshold
        self.noise_floor = 0.003
        self._pending = np.zeros(0, dtype=np.float32)
        self._segment = []
        self._speech_frames = 0
        self._silent_run = 0
        self._in_speech = False

    def feed(self, pcm_bytes: bytes):
        """Feed raw int16 bytes. Returns a list of finished segments."""
        if len(pcm_bytes) % 2:
            pcm_bytes = pcm_bytes[:-1]
        samples = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        self._pending = np.concatenate([self._pending, samples])
        out = []
        while len(self._pending) >= FRAME:
            frame = self._pending[:FRAME]
            self._pending = self._pending[FRAME:]
            seg = self._process_frame(frame)
            if seg is not None:
                out.append(seg)
        return out

    def flush(self):
        """End of stream: return whatever speech is buffered."""
        seg = self._emit()
        return [seg] if seg is not None else []

    def _process_frame(self, frame):
        rms = float(np.sqrt(np.mean(frame * frame)) + 1e-9)
        threshold = max(self.min_threshold, self.noise_floor * 3.0)
        is_speech = rms > threshold
        if not is_speech:
            # slowly track background noise level
            self.noise_floor = 0.95 * self.noise_floor + 0.05 * rms

        if is_speech:
            self._in_speech = True
            self._speech_frames += 1
            self._silent_run = 0
            self._segment.append(frame)
        elif self._in_speech:
            self._silent_run += 1
            self._segment.append(frame)  # keep short pauses inside the segment
            if self._silent_run >= self.silence_frames:
                return self._emit()
        if self._segment and len(self._segment) * FRAME >= self.max_samples:
            return self._emit()
        return None

    def _emit(self):
        seg = None
        if self._segment and self._speech_frames >= self.min_speech_frames:
            # trim trailing silence
            frames = self._segment[: len(self._segment) - self._silent_run] or self._segment
            seg = np.concatenate(frames)
        self._segment = []
        self._speech_frames = 0
        self._silent_run = 0
        self._in_speech = False
        return seg
