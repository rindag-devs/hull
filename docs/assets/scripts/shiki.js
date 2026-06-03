import { codeToHtml } from "https://esm.sh/shiki@4.2.0";

const aliases = {
  sh: "bash",
  shell: "bash",
  cpp: "cpp",
  cxx: "cpp",
  text: "text",
};

const darkThemes = new Set(["coal", "navy", "ayu"]);

function currentTheme() {
  for (const theme of darkThemes) {
    if (document.documentElement.classList.contains(theme)) return "dark";
  }
  return "light";
}

function languageOf(code) {
  for (const className of code.classList) {
    if (className.startsWith("language-")) {
      const lang = className.slice("language-".length);
      return aliases[lang] || lang;
    }
  }
  return "text";
}

let renderGeneration = 0;

async function renderShiki(code, generation) {
  const source = code.dataset.shikiSource || code.textContent;
  code.dataset.shikiSource = source;
  const lang = languageOf(code);
  const theme = currentTheme() === "dark" ? "github-dark" : "github-light";
  let html;

  try {
    html = await codeToHtml(source, {
      lang,
      theme,
    });
  } catch {
    html = await codeToHtml(source, {
      lang: "text",
      theme,
    });
  }

  const wrapper = document.createElement("div");
  wrapper.innerHTML = html;
  const shikiPre = wrapper.querySelector("pre");
  const shikiCode = wrapper.querySelector("code");
  if (!shikiPre || !shikiCode) return;
  if (generation !== renderGeneration) return;

  const pre = code.closest("pre");
  pre.classList.add(...shikiPre.classList);
  pre.style.cssText = shikiPre.style.cssText;
  pre.style.setProperty("--shiki-light-bg", "#f6f7f6");
  pre.style.setProperty("--shiki-dark-bg", "#2b303b");
  code.innerHTML = shikiCode.innerHTML;
  code.className = shikiCode.className || code.className;
  code.style.cssText = shikiCode.style.cssText;
}

function renderAll() {
  renderGeneration += 1;
  for (const code of document.querySelectorAll("pre > code")) {
    renderShiki(code, renderGeneration);
  }
}

renderAll();

let previousTheme = currentTheme();
new MutationObserver(() => {
  const nextTheme = currentTheme();
  if (nextTheme === previousTheme) return;
  previousTheme = nextTheme;
  renderAll();
}).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
