const nodes = document.querySelectorAll(".i18n");
const clock = document.querySelector("#clock");
const langBtn = document.querySelector("#lang");
const menuBtn = document.querySelector("#menu");
const nav = document.querySelector("#nav");
const pit = document.querySelector("#pit");
const log = document.querySelector("#log");
const live = document.querySelector("#live");
const bell = document.querySelector("#bell");

const seed = [
  {
    zh: "09:30:00  护目镜锁定 · 开始读盘",
    en: "09:30:00  visor lock · reading the tape",
  },
  {
    zh: "09:30:06  身份规则 · 仅限 AI Agent 钱包",
    en: "09:30:06  identity rule · AI agent wallets",
  },
  {
    zh: "09:30:12  叙事并轨 · 股票 MEME × 代理人",
    en: "09:30:12  narratives merge · stock meme × agent",
  },
  {
    zh: "09:30:18  状态 · 概念演示，无真实行情",
    en: "09:30:18  status · concept demo, no live market",
  },
];

const rings = [
  {
    zh: "铃响 · 开盘仪式（演示）",
    en: "Bell · opening ritual (demo)",
  },
  {
    zh: "代理人就位 · 此页不连接钱包",
    en: "Agent ready · this page connects no wallet",
  },
  {
    zh: "社区席位 · 围观也算在场",
    en: "Community seat · watching counts as presence",
  },
];

let lang = "zh";
let ringCount = 0;

function apply(next) {
  lang = next === "en" ? "en" : "zh";
  document.documentElement.lang = lang === "en" ? "en" : "zh-Hans";
  nodes.forEach((el) => {
    const text = el.getAttribute(lang === "en" ? "data-en" : "data-zh");
    if (!text) return;
    if (el.tagName === "META") el.setAttribute("content", text);
    else el.textContent = text;
  });
  document.title =
    lang === "en"
      ? "STOCKAI | The AI-Powered Stock Meme Era"
      : "STOCKAI｜AI × Stock × MEME";
  langBtn.textContent = lang === "en" ? "中文" : "EN";
  langBtn.setAttribute(
    "aria-label",
    lang === "en" ? "切换到中文" : "Switch to English"
  );
  try {
    localStorage.setItem("stockai-lang", lang);
  } catch {
    /* private mode */
  }
  renderClock();
  renderLog();
}

function renderClock() {
  const formatted = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Shanghai",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date());
  const zone = lang === "en" ? "Shanghai" : "上海";
  clock.textContent = `${formatted} ${zone}`;
  clock.dateTime = new Date().toISOString();
}

function renderLog() {
  const lines = seed.concat(rings.slice(0, ringCount));
  log.replaceChildren();
  lines.forEach((line) => {
    const item = document.createElement("li");
    item.textContent = line[lang];
    log.appendChild(item);
  });
  log.scrollTop = log.scrollHeight;
}

langBtn.addEventListener("click", () => {
  apply(lang === "en" ? "zh" : "en");
});

menuBtn.addEventListener("click", () => {
  const open = nav.classList.toggle("is-open");
  menuBtn.setAttribute("aria-expanded", String(open));
});

nav.addEventListener("click", (event) => {
  if (!event.target.closest("a")) return;
  nav.classList.remove("is-open");
  menuBtn.setAttribute("aria-expanded", "false");
});

document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape") return;
  nav.classList.remove("is-open");
  menuBtn.setAttribute("aria-expanded", "false");
});

bell.addEventListener("click", () => {
  ringCount = Math.min(rings.length, ringCount + 1);
  renderLog();
  const newest = rings[ringCount - 1][lang];
  live.textContent = newest;
  pit.classList.add("is-ringing");
  window.setTimeout(() => pit.classList.remove("is-ringing"), 700);
  if (ringCount === rings.length) {
    bell.disabled = true;
  }
});

const links = [...nav.querySelectorAll("a")];
const sections = links
  .map((link) => document.querySelector(link.getAttribute("href")))
  .filter(Boolean);

if ("IntersectionObserver" in window) {
  const spy = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        links.forEach((link) => {
          const on = link.getAttribute("href") === `#${entry.target.id}`;
          if (on) link.setAttribute("aria-current", "true");
          else link.removeAttribute("aria-current");
        });
      });
    },
    { rootMargin: "-45% 0px -45% 0px", threshold: 0.01 }
  );
  sections.forEach((section) => spy.observe(section));
}

let saved = "zh";
try {
  saved = localStorage.getItem("stockai-lang") || "zh";
} catch {
  saved = "zh";
}
apply(saved);
window.setInterval(renderClock, 1000);
