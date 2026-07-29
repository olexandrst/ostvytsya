/* Інтерактивний квест у браузері через Google Gemini Live.
 *
 * На відміну від OpenAI (WebRTC напряму з браузера), Gemini Live працює по
 * WebSocket із сирим PCM, тож ходимо через міст на нашому сервері — ключ
 * Gemini лишається на сервері, а персону й голос задає теж він.
 *
 *   мікрофон → AudioWorklet → PCM16 16 кГц → WS → сервер → Gemini
 *   Gemini → сервер → WS → PCM16 24 кГц → черга відтворення → колонки
 */
(() => {
  "use strict";

  const IN_RATE = 16000;   // те, що чекає Gemini на вході
  const OUT_RATE = 24000;  // те, що Gemini віддає

  const btnStart = document.getElementById("btn-start");
  const btnStop = document.getElementById("btn-stop");
  const statusEl = document.getElementById("status");
  const transcriptEl = document.getElementById("transcript");

  let ws = null;
  let micCtx = null;      // AudioContext захоплення (16 кГц)
  let playCtx = null;     // AudioContext відтворення (24 кГц)
  let micStream = null;
  let workletNode = null;
  let nextPlayTime = 0;   // коли ставити наступний шматок аудіо
  let speaking = false;   // персонаж зараз говорить
  let idleTimer = null;
  const sources = new Set();

  // Поточні рядки транскрипту (доповнюються по шматках).
  let userLine = null;
  let agentLine = null;

  function setStatus(text, kind = "") {
    statusEl.textContent = text;
    statusEl.className = "status" + (kind ? " status-" + kind : "");
  }

  function line(who, cls) {
    const p = document.createElement("p");
    p.className = "line " + cls;
    const b = document.createElement("b");
    b.textContent = who + ": ";
    const span = document.createElement("span");
    p.append(b, span);
    transcriptEl.append(p);
    transcriptEl.scrollTop = transcriptEl.scrollHeight;
    return span;
  }

  function systemNote(text) {
    const p = document.createElement("p");
    p.className = "line line-system";
    p.textContent = text;
    transcriptEl.append(p);
    transcriptEl.scrollTop = transcriptEl.scrollHeight;
  }

  /** Мікрофон німий, поки персонаж говорить: його не перебити. */
  function setMuted(muted) {
    if (workletNode) workletNode.port.postMessage({ muted });
  }

  function markSpeaking() {
    speaking = true;
    setMuted(true);
    setStatus("🔇 Персонаж говорить — слухай", "speaking");
    // Кінець репліки ловимо за паузою в аудіопотоці: turn_complete приходить
    // тоді, коли модель ДОГЕНЕРУВАЛА, а звук ще може догравати з буфера.
    clearTimeout(idleTimer);
    const tail = Math.max(0, nextPlayTime - (playCtx ? playCtx.currentTime : 0));
    idleTimer = setTimeout(() => {
      speaking = false;
      setMuted(false);
      setStatus("🎙 Твоя черга — говори", "live");
    }, tail * 1000 + 500);
  }

  /** Поставити шматок PCM16 у чергу відтворення. */
  function playChunk(arrayBuffer) {
    if (!playCtx) return;
    const pcm = new Int16Array(arrayBuffer);
    if (!pcm.length) return;

    const buf = playCtx.createBuffer(1, pcm.length, OUT_RATE);
    const ch = buf.getChannelData(0);
    for (let i = 0; i < pcm.length; i += 1) ch[i] = pcm[i] / 0x8000;

    const src = playCtx.createBufferSource();
    src.buffer = buf;
    src.connect(playCtx.destination);
    // Склеюємо шматки встик, щоб мова не «заїкалася».
    const now = playCtx.currentTime;
    if (nextPlayTime < now) nextPlayTime = now + 0.05;
    src.start(nextPlayTime);
    nextPlayTime += buf.duration;
    sources.add(src);
    src.onended = () => sources.delete(src);

    markSpeaking();
  }

  function stopPlayback() {
    sources.forEach((s) => { try { s.stop(); } catch (_) {} });
    sources.clear();
    nextPlayTime = 0;
  }

  function handleEvent(evt) {
    switch (evt.type) {
      case "ready":
        setStatus("На зв'язку", "live");
        break;
      case "agent_text":
        if (!agentLine) agentLine = line(evt.who || window.CHAR_NAME, "line-agent");
        agentLine.textContent += evt.text || "";
        transcriptEl.scrollTop = transcriptEl.scrollHeight;
        break;
      case "user_text":
        if (!userLine) userLine = line("Гравець", "line-user");
        userLine.textContent += evt.text || "";
        transcriptEl.scrollTop = transcriptEl.scrollHeight;
        break;
      case "turn_complete":
        userLine = null;
        agentLine = null;
        break;
      case "error":
        systemNote("⚠️ " + (evt.message || "невідома помилка"));
        setStatus("Помилка", "error");
        break;
      default:
        break;
    }
  }

  async function start() {
    btnStart.disabled = true;
    transcriptEl.innerHTML = "";
    userLine = agentLine = null;
    setStatus("Питаю дозвіл на мікрофон…", "live");

    try {
      micStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });

      // Окремі контексти: захоплення строго на 16 кГц, відтворення на 24 кГц.
      micCtx = new AudioContext({ sampleRate: IN_RATE });
      playCtx = new AudioContext({ sampleRate: OUT_RATE });
      await micCtx.audioWorklet.addModule("/static/pcm-worklet.js");

      setStatus("З'єднуюсь…", "live");
      const proto = location.protocol === "https:" ? "wss:" : "ws:";
      ws = new WebSocket(`${proto}//${location.host}/ws/quest/${encodeURIComponent(window.CHAR_ID)}`);
      ws.binaryType = "arraybuffer";

      await new Promise((resolve, reject) => {
        ws.addEventListener("open", resolve, { once: true });
        ws.addEventListener("error", () => reject(new Error("не вдалося з'єднатися")), { once: true });
      });

      ws.addEventListener("message", (e) => {
        if (typeof e.data === "string") {
          try { handleEvent(JSON.parse(e.data)); } catch (_) {}
        } else {
          playChunk(e.data);
        }
      });
      ws.addEventListener("close", (e) => {
        if (e.code === 4401) systemNote("⚠️ Сесія входу застаріла — онови сторінку.");
        else if (e.code === 4404) systemNote("⚠️ Персонажа не знайдено.");
        stop(true);
        setStatus("З'єднання завершено");
      });

      const source = micCtx.createMediaStreamSource(micStream);
      workletNode = new AudioWorkletNode(micCtx, "pcm-capture");
      workletNode.port.onmessage = (e) => {
        if (ws && ws.readyState === WebSocket.OPEN) ws.send(e.data);
      };
      source.connect(workletNode);
      // Вузол треба «підключити» до графа, щоб він працював; гучність — нуль,
      // інакше дитина чула б саму себе.
      const silent = micCtx.createGain();
      silent.gain.value = 0;
      workletNode.connect(silent).connect(micCtx.destination);

      btnStart.hidden = true;
      btnStop.hidden = false;
      setStatus("Персонаж вітається…", "live");
    } catch (err) {
      console.error(err);
      let msg = err && err.message ? err.message : String(err);
      if (err && err.name === "NotAllowedError") {
        msg = "доступ до мікрофона заборонено — дозволь його в налаштуваннях браузера";
      }
      systemNote("⚠️ " + msg);
      setStatus("Не вдалося почати", "error");
      stop(true);
    } finally {
      btnStart.disabled = false;
    }
  }

  function stop(quiet = false) {
    clearTimeout(idleTimer);
    stopPlayback();
    if (ws) {
      try {
        if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "stop" }));
        ws.close();
      } catch (_) {}
      ws = null;
    }
    if (workletNode) { try { workletNode.disconnect(); } catch (_) {} workletNode = null; }
    if (micStream) { micStream.getTracks().forEach((t) => t.stop()); micStream = null; }
    for (const ctx of [micCtx, playCtx]) {
      if (ctx) { try { ctx.close(); } catch (_) {} }
    }
    micCtx = playCtx = null;
    btnStop.hidden = true;
    btnStart.hidden = false;
    if (!quiet) {
      setStatus("Квест завершено");
      systemNote("— Квест завершено —");
    }
  }

  btnStart.addEventListener("click", start);
  btnStop.addEventListener("click", () => stop(false));
  window.addEventListener("beforeunload", () => stop(true));
})();
