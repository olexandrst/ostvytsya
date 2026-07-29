/* Видалення персонажа зі списку. */
(() => {
  "use strict";

  document.querySelectorAll(".js-delete").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.id;
      const name = btn.dataset.name || id;
      if (!window.confirm(`Видалити персонажа «${name}»? Це незворотно.`)) return;

      btn.disabled = true;
      try {
        const resp = await fetch(`/api/characters/${encodeURIComponent(id)}/delete`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ csrf: window.CSRF }),
        });
        const data = await resp.json();
        if (!resp.ok) throw new Error(data.error || "не вдалося видалити");
        const card = document.querySelector(`.char[data-id="${CSS.escape(id)}"]`);
        if (card) card.remove();
      } catch (err) {
        window.alert("⚠️ " + (err.message || err));
        btn.disabled = false;
      }
    });
  });
})();
