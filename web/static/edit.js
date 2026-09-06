/* Створення та збереження персонажа. */
(() => {
  "use strict";

  const form = document.getElementById("char-form");
  const msg = document.getElementById("msg");
  const creating = form.dataset.creating === "yes";

  // Показуємо лише той список голосів, що належить обраній моделі.
  const providerSel = document.getElementById("provider");
  function syncVoiceFields() {
    const provider = providerSel.value;
    form.querySelectorAll("[data-voice-for]").forEach((el) => {
      el.hidden = el.dataset.voiceFor !== provider;
    });
    // Швидкість мовлення підтримує лише OpenAI — поле лишаємо активним, щоб
    // значення не загубилося при перемиканні, але позначаємо приміткою.
    const note = form.querySelector("[data-speed-note]");
    if (note) note.hidden = provider !== "google";
  }
  if (providerSel) {
    providerSel.addEventListener("change", syncVoiceFields);
    syncVoiceFields();
  }

  function show(text, kind) {
    msg.textContent = text;
    msg.className = "alert alert-" + kind;
    msg.hidden = false;
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  // «Скинути до типового»: персонаж повертається до версії з комплекту
  // (characters/*.yaml у репозиторії) — усі правки у веб-редакторі втрачаються.
  const resetBtn = document.getElementById("reset-default");
  if (resetBtn) {
    resetBtn.addEventListener("click", async () => {
      const id = resetBtn.dataset.id;
      const name = resetBtn.dataset.name || id;
      if (!window.confirm(
        `Скинути персонажа «${name}» до типової версії з комплекту? ` +
        "Усі правки промпту, голосу й кодових слів у веб-редакторі буде втрачено."
      )) return;
      resetBtn.disabled = true;
      try {
        const resp = await fetch(`/api/characters/${encodeURIComponent(id)}/reset`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ csrf: window.CSRF }),
        });
        const data = await resp.json();
        if (!resp.ok) throw new Error(data.error || "не вдалося скинути");
        // Перезавантажуємо сторінку — форма має показати типову версію.
        window.location.reload();
      } catch (err) {
        show("⚠️ " + (err.message || err), "error");
        resetBtn.disabled = false;
      }
    });
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const fd = new FormData(form);
    const body = { csrf: window.CSRF };
    fd.forEach((v, k) => { body[k] = v; });

    const url = creating
      ? "/api/characters"
      : `/api/characters/${encodeURIComponent(form.dataset.id)}`;

    const btn = form.querySelector('button[type="submit"]');
    btn.disabled = true;
    try {
      const resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const data = await resp.json();
      if (!resp.ok) throw new Error(data.error || "не вдалося зберегти");
      if (creating) {
        window.location.href = `/characters/${encodeURIComponent(data.id)}/edit`;
      } else {
        show("Збережено ✓", "ok");
      }
    } catch (err) {
      show("⚠️ " + (err.message || err), "error");
    } finally {
      btn.disabled = false;
    }
  });
})();
