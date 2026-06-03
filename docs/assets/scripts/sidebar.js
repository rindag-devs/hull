"use strict";

// Mirrors mdBook's sidebar_header_nav behavior for the inline Tola sidebar.
(function sidebarHeaderNavigation() {
  let lastKnownScrollPosition = 0;
  const defaultDownThreshold = 150;
  const defaultUpThreshold = 300;
  let threshold = defaultDownThreshold;
  let disableScroll = false;
  let headers = [];
  let headerToggles = [];

  function slug(text, counts) {
    const base =
      text
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9\u4e00-\u9fff]+/g, "-")
        .replace(/^-+|-+$/g, "") || "section";
    const count = counts.get(base) || 0;
    counts.set(base, count + 1);
    return count === 0 ? base : `${base}-${count + 1}`;
  }

  function updateThreshold() {
    const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
    const windowHeight = window.innerHeight;
    const documentHeight = document.documentElement.scrollHeight;
    const pixelsBelow = Math.max(0, documentHeight - (scrollTop + windowHeight));
    const pixelsAbove = Math.max(0, defaultDownThreshold - scrollTop);
    const bottomAdd = Math.max(0, windowHeight - pixelsBelow - defaultDownThreshold);
    let adjustedBottomAdd = bottomAdd;

    if (documentHeight < windowHeight * 2) {
      const maxPixelsBelow = documentHeight - windowHeight;
      const t = 1 - pixelsBelow / Math.max(1, maxPixelsBelow);
      adjustedBottomAdd *= Math.max(0, Math.min(1, t));
    }

    if (scrollTop >= lastKnownScrollPosition) {
      const amountScrolledDown = scrollTop - lastKnownScrollPosition;
      const adjustedDefault = defaultDownThreshold + adjustedBottomAdd;
      threshold = Math.max(adjustedDefault, threshold - amountScrolledDown);
    } else {
      const amountScrolledUp = lastKnownScrollPosition - scrollTop;
      const adjustedDefault =
        defaultUpThreshold - pixelsAbove + Math.max(0, adjustedBottomAdd - defaultDownThreshold);
      threshold = Math.min(adjustedDefault, threshold + amountScrolledUp);
    }

    if (documentHeight <= windowHeight) threshold = 0;
    lastKnownScrollPosition = scrollTop;
  }

  function updateHeaderExpanded(currentA) {
    let current = currentA.parentElement;
    while (current) {
      if (current.tagName === "LI" && current.classList.contains("header-item")) {
        current.classList.add("expanded");
      }
      current = current.parentElement;
    }
  }

  function updateCurrentHeader() {
    if (!headers.length) return;

    for (const el of document.getElementsByClassName("current-header")) {
      el.classList.remove("current-header");
    }
    for (const toggle of headerToggles) {
      toggle.classList.remove("expanded");
    }

    let lastHeader = null;
    for (const header of headers) {
      if (header.getBoundingClientRect().top <= threshold) {
        lastHeader = header;
      } else {
        break;
      }
    }
    if (lastHeader === null) {
      lastHeader = headers[0];
      if (lastHeader.getBoundingClientRect().top >= window.innerHeight) return;
    }

    const a = [...document.querySelectorAll(".header-in-summary")].find(
      (element) => element.getAttribute("href") === `#${lastHeader.id}`,
    );
    if (!a) return;

    a.classList.add("current-header");
    updateHeaderExpanded(a);
  }

  function reloadCurrentHeader() {
    if (disableScroll) return;
    updateThreshold();
    updateCurrentHeader();
  }

  function headerThresholdClick(event) {
    disableScroll = true;
    setTimeout(() => {
      disableScroll = false;
    }, 100);
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const a = event.target.closest("a");
        const targetElement = document.getElementById(a.getAttribute("href").substring(1));
        if (targetElement) {
          threshold = targetElement.getBoundingClientRect().bottom;
          updateCurrentHeader();
        }
      });
    });
  }

  function appendHeaderText(source, dest) {
    for (const node of source.childNodes) {
      if (node.nodeType === Node.ELEMENT_NODE && node.tagName === "MARK") {
        dest.append(...node.childNodes);
      } else {
        dest.appendChild(node.cloneNode(true));
      }
    }
  }

  function init() {
    document.querySelectorAll("#mdbook-sidebar .on-this-page").forEach((el) => {
      el.remove();
    });

    const activeSection = document.querySelector("#mdbook-sidebar .active");
    if (!activeSection) return;

    const main = document.getElementsByTagName("main")[0];
    if (!main) return;

    const counts = new Map();
    headers = Array.from(main.querySelectorAll("h2, h3, h4, h5, h6"));
    for (const header of headers) {
      if (!header.id) header.id = slug(header.textContent, counts);
    }
    headers = headers.filter((header) => header.id);
    if (!headers.length) return;

    const stack = [];
    const firstLevel = parseInt(headers[0].tagName.charAt(1), 10);
    for (let i = 1; i < firstLevel; i++) {
      const ol = document.createElement("ol");
      ol.classList.add("section");
      if (stack.length > 0) stack[stack.length - 1].ol.appendChild(ol);
      stack.push({ level: i + 1, ol });
    }

    const foldLevel = 3;
    headerToggles = [];

    for (let i = 0; i < headers.length; i++) {
      const header = headers[i];
      const level = parseInt(header.tagName.charAt(1), 10);
      const currentLevel = stack[stack.length - 1].level;

      if (level > currentLevel) {
        for (let nextLevel = currentLevel + 1; nextLevel <= level; nextLevel++) {
          const ol = document.createElement("ol");
          ol.classList.add("section");
          const last = stack[stack.length - 1];
          const lastChild = last.ol.lastChild;
          if (lastChild) lastChild.appendChild(ol);
          else last.ol.appendChild(ol);
          stack.push({ level: nextLevel, ol });
        }
      } else if (level < currentLevel) {
        while (stack.length > 1 && stack[stack.length - 1].level > level) stack.pop();
      }

      const li = document.createElement("li");
      li.classList.add("header-item", "expanded");
      if (level < foldLevel) li.classList.add("expanded");

      const span = document.createElement("span");
      span.classList.add("chapter-link-wrapper");
      const a = document.createElement("a");
      a.href = `#${header.id}`;
      a.classList.add("header-in-summary");
      appendHeaderText(header, a);
      a.addEventListener("click", headerThresholdClick);
      span.appendChild(a);

      const nextHeader = headers[i + 1];
      if (nextHeader !== undefined) {
        const nextLevel = parseInt(nextHeader.tagName.charAt(1), 10);
        if (nextLevel > level && level >= foldLevel) {
          const toggle = document.createElement("a");
          toggle.classList.add("chapter-fold-toggle", "header-toggle");
          toggle.addEventListener("click", () => li.classList.toggle("expanded"));
          const toggleDiv = document.createElement("div");
          toggleDiv.textContent = "❱";
          toggle.appendChild(toggleDiv);
          span.appendChild(toggle);
          headerToggles.push(li);
        }
      }

      li.appendChild(span);
      stack[stack.length - 1].ol.appendChild(li);
    }

    const onThisPage = document.createElement("div");
    onThisPage.classList.add("on-this-page");
    onThisPage.append(stack[0].ol);
    activeSection.after(onThisPage);
    reloadCurrentHeader();
  }

  document.addEventListener("DOMContentLoaded", init);
  document.addEventListener("DOMContentLoaded", reloadCurrentHeader);
  document.addEventListener("scroll", reloadCurrentHeader, { passive: true });
})();
