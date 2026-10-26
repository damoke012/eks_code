// Converts browser audio (44.1/48 kHz float) to 16 kHz mono int16 and posts ~100 ms chunks.
class PcmDownsampler extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / 16000;
    this.pos = 0;          // fractional read position into the input stream
    this.prev = 0;         // last sample of previous block (for interpolation)
    this.out = new Int16Array(1600);
    this.n = 0;
  }
  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    // mix all channels to mono
    const len = input[0].length;
    const mono = new Float32Array(len);
    for (let c = 0; c < input.length; c++) {
      const ch = input[c];
      for (let i = 0; i < len; i++) mono[i] += ch[i] / input.length;
    }
    while (this.pos < len) {
      const i = Math.floor(this.pos);
      const frac = this.pos - i;
      const a = i === 0 ? this.prev : mono[i - 1];
      const b = mono[i];
      let s = a + (b - a) * frac;
      s = Math.max(-1, Math.min(1, s));
      this.out[this.n++] = s < 0 ? s * 0x8000 : s * 0x7fff;
      if (this.n === this.out.length) {
        this.port.postMessage(this.out.buffer, [this.out.buffer]);
        this.out = new Int16Array(1600);
        this.n = 0;
      }
      this.pos += this.ratio;
    }
    this.pos -= len;
    this.prev = mono[len - 1];
    return true;
  }
}
registerProcessor('pcm-downsampler', PcmDownsampler);
