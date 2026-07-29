/* Інтерактивний квест у браузері через OpenAI Realtime (WebRTC).
 *
 * Схема: сервер видає короткоживучий ephemeral-токен (справжній ключ OpenAI
 * лишається на сервері), а браузер із цим токеном піднімає WebRTC-з'єднання
 * просто до OpenAI — звук іде напряму, з мінімальною затримкою.
 */
(() => {
  "use strict";

  const CALLS_URL = "https://api.openai.com/v1/realtime/calls";

  const btnStart = document.getElementById("btn-start");
  const btnStop = document.getElementById("btn-stop");
  const statusEl = document.getElementById("status");
  const transcriptEl = document.getElementById("transcript");
  const audioEl = document.getElementById("remote-audio");

  let pc = null;        // RTCPeerConnection
  let micStream = null; // локальний мікрофон
  let dc = null;        // канал подій "oai-events"

  // Рядки транскрипту, які ще доповнюються (id → елемент).
  const pending = new Map();

  function setStatus(text, kind = "") {
    statusEl.textContent = text;
    statusEl.className = "status" + (kind ? " status-" + kind : "");
  }

  function clearTranscript() {
    transcriptEl.innerHTML = "";
    pending.clear();
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

  /** Дописати шматок тексту до рядка, створивши його за потреби. */
  function appendChunk(key, who, cls, text) {
    if (!text) return;
    let span = pending.get(key);
    if (!span) {
      span = line(who, cls);
      pending.set(key, span);
    }
    span.textContent += text;
    transcriptEl.scrollTop = transcriptEl.scrollHeight;
  }

  function finishLine(key) {
    pending.delete(key);
  }

  function systemNote(text) {
    const p = document.createElement("p");
    p.className = "line line-system";
    p.textContent = text;
    transcriptEl.append(p);
    transcriptEl.scrollTop = transcriptEl.scrollHeight;
  }

  /** Обробка подій Realtime API. Імена подій GA, з запасними варіантами. */
  function handleEvent(evt) {
    const type = evt.type || "";

    // Діагностика: чи справді дійшов сценарій персонажа. Якщо інструкції
    // порожні — персонаж почне імпровізувати, і це треба помітити одразу.
    if (type === "session.created" || type === "session.updated") {
      const instr = (evt.session && evt.session.instructions) || "";
      console.info(`[Оствиця] сесія: інструкцій ${instr.length} символів`);
      if (type === "session.created" && !instr) {
        systemNote("⚠️ Сценарій персонажа не дійшов до моделі — вона говоритиме " +
                   "від себе. Перевір лог сервера.");
      }
      return;
    }

    // Відповідь персонажа (транскрипт синтезованого мовлення).
    if (type === "response.output_audio_transcript.delta" ||
        type === "response.audio_transcript.delta") {
      appendChunk("out:" + (evt.item_id || evt.response_id || "cur"),
                  window.CHAR_NAME, "line-agent", evt.delta || "");
      return;
    }
    if (type === "response.output_audio_transcript.done" ||
        type === "response.audio_transcript.done") {
      finishLine("out:" + (evt.item_id || evt.response_id || "cur"));
      return;
    }

    // Мовлення дитини (розпізнане).
    if (type === "conversation.item.input_audio_transcription.delta") {
      appendChunk("in:" + (evt.item_id || "cur"), "Гравець", "line-user", evt.delta || "");
      return;
    }
    if (type === "conversation.item.input_audio_transcription.completed") {
      const key = "in:" + (evt.item_id || "cur");
      if (!pending.has(key) && evt.transcript) {
        appendChunk(key, "Гравець", "line-user", evt.transcript);
      }
      finishLine(key);
      return;
    }

    if (type === "input_audio_buffer.speech_started") {
      setStatus("Слухаю…", "live");
      return;
    }
    if (type === "input_audio_buffer.speech_stopped") {
      setStatus("Персонаж думає…", "live");
      return;
    }
    if (type === "response.done") {
      setStatus("Твоя черга — говори", "live");
      return;
    }
    if (type === "error") {
      const msg = (evt.error && (evt.error.message || evt.error.code)) || "невідома помилка";
      systemNote("⚠️ Помилка: " + msg);
      setStatus("Помилка", "error");
    }
  }

  /** Попросити персонажа заговорити першим.
   *
   * Тригер іде як ПОВІДОМЛЕННЯ КОРИСТУВАЧА, а не як response.instructions:
   * instructions у response.create замінюють системні інструкції для цієї
   * відповіді, тож персонаж почав би вітання, не бачачи власного сценарію,
   * і вигадав би собі квест.
   */
  function greet(greeting) {
    if (!dc || dc.readyState !== "open") return;
    dc.send(JSON.stringify({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: greeting }],
      },
    }));
    dc.send(JSON.stringify({ type: "response.create" }));
    setStatus("Персонаж вітається…", "live");
  }

  async function start() {
    btnStart.disabled = true;
    clearTranscript();
    setStatus("З'єднуюсь…", "live");

    try {
      // 1. Токен від нашого сервера (він же задає персонажа, голос і промпт).
      const tokenResp = await fetch(`/api/realtime/token/${encodeURIComponent(window.CHAR_ID)}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ csrf: window.CSRF }),
      });
      const tokenData = await tokenResp.json();
      if (!tokenResp.ok) throw new Error(tokenData.error || "не вдалося отримати токен");

      // 2. Мікрофон.
      setStatus("Питаю дозвіл на мікрофон…", "live");
      micStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      });

      // 3. WebRTC просто до OpenAI.
      pc = new RTCPeerConnection();
      pc.ontrack = (e) => { audioEl.srcObject = e.streams[0]; };
      pc.addTrack(micStream.getTracks()[0], micStream);

      dc = pc.createDataChannel("oai-events");
      dc.addEventListener("open", () => greet(tokenData.greeting));
      dc.addEventListener("message", (e) => {
        try { handleEvent(JSON.parse(e.data)); } catch (_) { /* не-JSON ігноруємо */ }
      });

      pc.addEventListener("connectionstatechange", () => {
        if (pc && (pc.connectionState === "failed" || pc.connectionState === "disconnected")) {
          setStatus("З'єднання втрачено", "error");
          systemNote("⚠️ З'єднання перервалося. Спробуй запустити квест ще раз.");
          stop(true);
        }
      });

      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      const sdpResp = await fetch(CALLS_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${tokenData.client_secret}`,
          "Content-Type": "application/sdp",
        },
        body: offer.sdp,
      });
      if (!sdpResp.ok) {
        throw new Error(`OpenAI відхилив з'єднання (${sdpResp.status}): ${await sdpResp.text()}`);
      }
      await pc.setRemoteDescription({ type: "answer", sdp: await sdpResp.text() });

      btnStart.hidden = true;
      btnStop.hidden = false;
      setStatus("На зв'язку", "live");
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
    if (dc) { try { dc.close(); } catch (_) {} dc = null; }
    if (pc) { try { pc.close(); } catch (_) {} pc = null; }
    if (micStream) {
      micStream.getTracks().forEach((t) => t.stop());
      micStream = null;
    }
    audioEl.srcObject = null;
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
