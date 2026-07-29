/* AudioWorklet: забирає мікрофон і віддає сирий PCM16 кадрами по ~40 мс.
 *
 * Gemini Live чекає 16 кГц PCM16 моно. AudioContext ми створюємо одразу на
 * 16 кГц, тож тут лишається тільки перевести float(-1..1) у int16 і накопичити
 * достатньо семплів, щоб не слати сотні крихітних повідомлень.
 */
class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.chunk = 640; // 40 мс на 16 кГц
    this.buffer = new Int16Array(this.chunk);
    this.filled = 0;
    this.muted = false;
    this.port.onmessage = (e) => {
      if (e.data && typeof e.data.muted === "boolean") this.muted = e.data.muted;
    };
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || !input[0]) return true;
    const samples = input[0];

    for (let i = 0; i < samples.length; i += 1) {
      // Поки персонаж говорить, шлемо тишу: так модель не чує ні дитину, ні
      // власне відлуння з колонок, і її неможливо перебити.
      let s = this.muted ? 0 : Math.max(-1, Math.min(1, samples[i]));
      this.buffer[this.filled] = s < 0 ? s * 0x8000 : s * 0x7fff;
      this.filled += 1;
      if (this.filled === this.chunk) {
        // Копію передаємо як передавану ArrayBuffer — без зайвих алокацій.
        const out = this.buffer.slice(0);
        this.port.postMessage(out.buffer, [out.buffer]);
        this.filled = 0;
      }
    }
    return true;
  }
}

registerProcessor("pcm-capture", PcmCaptureProcessor);
