const menuButton = document.querySelector(".nav-toggle");
const navigation = document.querySelector(".site-nav");
const modelsMenu = navigation.querySelector("details");
const searchButton = document.querySelector(".search-toggle");
const searchDialog = document.querySelector("#site-search");
const searchField = searchDialog.querySelector("input");
const results = document.querySelector("#search-results");
const statusMessage = document.querySelector("#search-status");

document.documentElement.classList.add("js");
menuButton.hidden = false;
menuButton.addEventListener("click", () => {
  const open = navigation.classList.toggle("is-open");
  menuButton.setAttribute("aria-expanded", String(open));
  if (!open) modelsMenu.open = false;
});

document.addEventListener("click", event => {
  if (!modelsMenu.contains(event.target)) modelsMenu.open = false;
});
document.addEventListener("keydown", event => {
  if (event.key !== "Escape" || searchDialog.open) return;
  if (modelsMenu.open) {
    modelsMenu.open = false;
    modelsMenu.querySelector("summary").focus();
  } else if (navigation.classList.contains("is-open")) {
    navigation.classList.remove("is-open");
    menuButton.setAttribute("aria-expanded", "false");
    menuButton.focus();
  }
});

function normalize(value) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();
}

function showMatches() {
  const query = normalize(searchField.value.trim());
  results.replaceChildren();
  statusMessage.textContent = "";
  if (!query) return;
  const terms = query.split(/\s+/);
  const matches = window.siteSearchIndex.filter(entry => {
    const text = normalize(entry.page + " " + entry.text);
    return terms.every(term => text.includes(term));
  });
  statusMessage.textContent = matches.length === 1 ? "1 result" : matches.length + " results";
  for (const entry of matches) {
    const li = document.createElement("li");
    const link = document.createElement("a");
    link.href = document.body.dataset.root + entry.href;
    link.textContent = entry.heading && normalize(entry.page) !== normalize(entry.heading)
      ? entry.page + " · " + entry.heading : entry.page;
    const snippet = document.createElement("small");
    const start = Math.max(0, normalize(entry.text).indexOf(terms[0]) - 45);
    snippet.textContent = (start ? "…" : "") + entry.text.slice(start, start + 150)
      + (entry.text.length > start + 150 ? "…" : "");
    li.append(link, snippet);
    results.append(li);
  }
}

if (window.siteSearchIndex && typeof searchDialog.showModal === "function") {
  searchButton.hidden = false;
  searchButton.addEventListener("click", () => {
    searchDialog.showModal();
    searchField.focus();
    searchField.select();
  });
  searchField.addEventListener("input", showMatches);
  searchDialog.querySelector("button").addEventListener("click", () => searchDialog.close());
  results.addEventListener("click", event => {
    if (event.target.closest("a")) searchDialog.close();
  });
}

for (const link of document.querySelectorAll(".video-link")) {
  link.addEventListener("click", event => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const frame = document.createElement("iframe");
    frame.title = link.getAttribute("aria-label");
    frame.src = link.dataset.player + "?autoplay=1";
    frame.allow = "autoplay; fullscreen; picture-in-picture";
    frame.allowFullscreen = true;
    link.replaceWith(frame);
    frame.focus();
  });
}
