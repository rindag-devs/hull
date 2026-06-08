"use strict";

(function pagefindSearch() {
  const button = document.getElementById("pagefind-search-toggle");
  const panel = document.getElementById("pagefind-search-panel");
  const root = document.getElementById("pagefind-search");
  if (!button || !panel || !root || typeof PagefindUI === "undefined") {
    return;
  }
  let initialized = false;

  function initialize() {
    if (initialized) {
      return;
    }
    initialized = true;
    new PagefindUI({
      element: "#pagefind-search",
      showSubResults: true,
      resetStyles: false,
      pageSize: 10,
    });
  }

  function input() {
    return root.querySelector(".pagefind-ui__search-input");
  }

  function open() {
    initialize();
    panel.classList.remove("hidden");
    button.setAttribute("aria-expanded", "true");
    requestAnimationFrame(() => input()?.focus());
  }

  function close() {
    panel.classList.add("hidden");
    button.setAttribute("aria-expanded", "false");
  }

  function toggle() {
    if (panel.classList.contains("hidden")) {
      open();
    } else {
      close();
    }
  }

  button.addEventListener("click", toggle);

  function editableElementHasFocus() {
    const active = document.activeElement;
    return active?.matches?.("input, select, textarea, [contenteditable]");
  }

  document.addEventListener("keydown", (event) => {
    if (event.ctrlKey || event.metaKey || event.altKey) {
      return;
    }
    if (editableElementHasFocus()) {
      return;
    }
    if (event.key === "/" || event.key === "s") {
      event.preventDefault();
      open();
    } else if (event.key === "Escape" && !panel.classList.contains("hidden")) {
      close();
      button.focus();
    }
  });
})();
