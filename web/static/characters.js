/* Дії над персонажами у списку: клонування та видалення. */
(() => {
  "use strict";

  document.querySelectorAll(".js-clone").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const id = btn.dataset.id;
      btn.disabled = true;
      const label = btn.textContent;
      btn.textContent = "Копіюю…";
      try {
        const resp = await fetch(`/api/characters/${encodeURIComponent(id)}/clone`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ csrf: window.CSRF }),
        });
        const data = await resp.json();
        if (!resp.ok) throw new Error(data.error || "не вдалося клонувати");
        // Одразу відкриваємо копію на редагування — зазвичай саме це й потрібно.
        window.location.href = `/characters/${encodeURIComponent(data.id)}/edit`;
      } catch (err) {
        window.alert("⚠️ " + (err.message || err));
        btn.disabled = false;
        btn.textContent = label;
      }
    });
  });

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
