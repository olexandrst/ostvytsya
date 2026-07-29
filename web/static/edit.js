/* Створення та збереження персонажа. */
(() => {
  "use strict";

  const form = document.getElementById("char-form");
  const msg = document.getElementById("msg");
  const creating = form.dataset.creating === "yes";

  function show(text, kind) {
    msg.textContent = text;
    msg.className = "alert alert-" + kind;
    msg.hidden = false;
    window.scrollTo({ top: 0, behavior: "smooth" });
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
