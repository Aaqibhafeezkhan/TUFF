// TUFF community benchmarks. Reads data.json, which the Pages workflow
// builds from GitHub Discussions at deploy time. Every value from a post is
// rendered with textContent, never as HTML.
"use strict";

const state = {
  data: null,
  error: null,
  filters: { model: "", chip: "", memory: "", tuff: "", held: false },
  grouped: true,
  sort: { key: "decode", descending: true },
};

const REFRESH_MS = 60_000;

// ---- small DOM helpers ---------------------------------------------------

function el(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : String(value));
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const rate = (value) => value == null ? "–" : `${value >= 10 ? value.toFixed(1) : value.toFixed(2)} tok/s`;
const seconds = (value) => value == null ? "–" : (value >= 10 ? `${value.toFixed(0)} s` : `${value.toFixed(1)} s`);
const chipShort = (chip) => chip.replace(/^Apple /, "");
const mac = (chip, memory) => `${chipShort(chip)}, ${memory} GB`;
const encode = (value) => encodeURIComponent(value);
const modelName = (id) => state.data?.models?.[id] ?? id;

function compareVersions(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i += 1) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) - (pb[i] || 0);
  return 0;
}

function trustBadge(trust) {
  if (trust === "verified") return el("span", { class: "badge verified" }, "verified");
  if (trust === "needs-review") return el("span", { class: "badge held" }, "held");
  return el("span", { class: "badge" }, "community");
}

// ---- data ----------------------------------------------------------------

async function load() {
  try {
    const response = await fetch(`data.json?t=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.data = await response.json();
    state.error = null;
  } catch (error) {
    if (!state.data) state.error = "The results could not be loaded. Try again in a minute.";
  }
  render();
}

function filteredEntries() {
  const f = state.filters;
  return (state.data?.entries ?? []).filter((entry) =>
    (!f.model || entry.model === f.model)
    && (!f.chip || entry.chip === f.chip)
    && (!f.memory || String(entry.memory_gb) === f.memory)
    && (!f.tuff || entry.tuff === f.tuff)
    && (f.held || entry.trust !== "needs-review"));
}

function filteredGroups() {
  const f = state.filters;
  return (state.data?.groups ?? []).filter((group) =>
    (!f.model || group.model === f.model)
    && (!f.chip || group.chip === f.chip)
    && (!f.memory || String(group.memory_gb) === f.memory)
    && (!f.tuff || group.tuff === f.tuff));
}

function sorted(rows) {
  const { key, descending } = state.sort;
  return [...rows].sort((a, b) => {
    const x = a[key];
    const y = b[key];
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    const order = typeof x === "string" ? x.localeCompare(y) : x - y;
    return descending ? -order : order;
  });
}

// ---- views ---------------------------------------------------------------

function render() {
  const view = document.getElementById("view");
  const route = decodeURIComponent(location.hash.replace(/^#\/?/, "")).split("/");
  view.replaceChildren();
  if (state.error) {
    view.append(el("div", { class: "state" }, state.error));
    return;
  }
  if (!state.data) {
    view.append(el("div", { class: "state" }, "Loading results…"));
    return;
  }
  if (route[0] === "model" && route[1]) return renderModel(view, route[1]);
  if (route[0] === "mac" && route[1] && route[2]) return renderMac(view, route[1], Number(route[2]));
  if (route[0] === "post" && route[1]) return renderPost(view, Number(route[1]));
  renderLeaderboard(view);
}

function setHeader(title, lead, crumb) {
  document.getElementById("title").textContent = title;
  document.getElementById("lead").textContent = lead;
  const extra = document.getElementById("crumb-extra");
  extra.textContent = crumb ? ` / ${crumb}` : "";
  document.title = crumb ? `${crumb}: TUFF Benchmarks` : "TUFF Benchmarks: local LLM speed on Apple Silicon Macs";
}

function emptyState() {
  return el("div", { class: "state" },
    "No results here yet. Be the first: open Benchmarks in TUFF, run it, and share.");
}

function renderLeaderboard(view) {
  setHeader("Benchmarks",
    "How fast models run in TUFF on real Macs, measured by the people who own them. Every result comes from TUFF's built-in benchmark and links to the post it came from.");
  view.append(filters());
  if (state.grouped) {
    const rows = sorted(filteredGroups());
    view.append(rows.length ? groupTable(rows) : emptyState());
  } else {
    const rows = sorted(filteredEntries());
    view.append(rows.length ? entryTable(rows) : emptyState());
  }
  view.append(el("p", { class: "note" },
    `Updated ${new Date(state.data.generated).toLocaleString()}. New posts usually appear within a few minutes.`));
}

function filters() {
  const entries = state.data.entries;
  const options = (values, label, key, format = (v) => v) => {
    const select = el("select", {
      "aria-label": label,
      onchange: (event) => { state.filters[key] = event.target.value; render(); },
    }, el("option", { value: "" }, label));
    for (const value of values) {
      const option = el("option", { value }, format(value));
      if (String(state.filters[key]) === String(value)) option.selected = true;
      select.append(option);
    }
    return select;
  };
  const unique = (key) => [...new Set(entries.map((e) => e[key]))];
  const segmented = el("div", { class: "segmented", role: "group", "aria-label": "View" },
    el("button", { type: "button", "aria-pressed": String(state.grouped),
      onclick: () => { state.grouped = true; render(); } }, "Grouped"),
    el("button", { type: "button", "aria-pressed": String(!state.grouped),
      onclick: () => { state.grouped = false; render(); } }, "Every result"));
  const held = el("label", { class: "toggle" },
    el("input", { type: "checkbox", checked: state.filters.held,
      onchange: (event) => { state.filters.held = event.target.checked; render(); } }),
    "Show held results");
  return el("div", { class: "controls" },
    segmented,
    options(Object.keys(state.data.models).filter((id) => unique("model").includes(id)), "All models", "model", modelName),
    options(unique("chip").sort(), "All chips", "chip", chipShort),
    options(unique("memory_gb").sort((a, b) => a - b), "All memory", "memory", (v) => `${v} GB`),
    options(unique("tuff").sort(compareVersions).reverse(), "All versions", "tuff", (v) => `TUFF ${v}`),
    state.grouped ? null : held);
}

function header(label, key, numeric = true) {
  const active = state.sort.key === key;
  const th = el("th", {
    class: numeric ? "num" : null,
    "aria-sort": active ? (state.sort.descending ? "descending" : "ascending") : null,
  }, el("button", { type: "button", onclick: () => {
    state.sort = { key, descending: active ? !state.sort.descending : numeric };
    render();
  } }, label));
  return th;
}

function table(head, rows) {
  return el("div", { class: "table-wrap" },
    el("table", {}, el("thead", {}, el("tr", {}, head)), el("tbody", {}, rows)));
}

function groupTable(rows) {
  return table([
    header("Model", "model", false), header("Mac", "chip", false), header("TUFF", "tuff", false),
    header("Writes", "decode"), header("Reads prompt", "prefill"), header("First token", "ttft"),
    header("Follow-up", "followup_ttft"), header("People", "contributors"),
  ], rows.map((row) => el("tr", {},
    el("td", {}, el("a", { href: `#model/${encode(row.model)}` }, modelName(row.model)),
      row.verified ? [" ", trustBadge("verified")] : null),
    el("td", {}, el("a", { href: `#mac/${encode(row.chip)}/${row.memory_gb}` }, mac(row.chip, row.memory_gb))),
    el("td", {}, row.tuff),
    el("td", { class: "num" }, rate(row.decode),
      row.contributors > 1 && row.decode_low != null
        ? el("span", { class: "range" }, `${row.decode_low}–${row.decode_high}`) : null),
    el("td", { class: "num" }, rate(row.prefill)),
    el("td", { class: "num" }, seconds(row.ttft)),
    el("td", { class: "num" }, seconds(row.followup_ttft)),
    el("td", { class: "num" }, `${row.contributors}`),
  )));
}

function entryTable(rows, showModel = true) {
  return table([
    showModel ? header("Model", "model", false) : null, header("Mac", "chip", false),
    header("TUFF", "tuff", false), header("Writes", "decode"), header("Reads prompt", "prefill"),
    header("First token", "ttft"), header("Follow-up", "followup_ttft"), header("Posted", "posted", false),
    el("th", {}, "Trust"),
  ], rows.map((row) => el("tr", {},
    showModel ? el("td", {}, el("a", { href: `#model/${encode(row.model)}` }, row.model_name)) : null,
    el("td", {}, el("a", { href: `#mac/${encode(row.chip)}/${row.memory_gb}` }, mac(row.chip, row.memory_gb))),
    el("td", {}, row.tuff),
    el("td", { class: "num" }, rate(row.decode)),
    el("td", { class: "num" }, rate(row.prefill)),
    el("td", { class: "num" }, seconds(row.ttft)),
    el("td", { class: "num" }, seconds(row.followup_ttft)),
    el("td", {}, el("a", { href: `#post/${row.post}` }, `#${row.post}`), ` by ${row.author}`),
    el("td", {}, trustBadge(row.trust)),
  )));
}

function renderModel(view, model) {
  const name = modelName(model);
  setHeader(name, `${name} on every Mac people have measured, fastest first.`, name);
  const groups = sorted((state.data.groups ?? []).filter((g) => g.model === model));
  const entries = (state.data.entries ?? []).filter((e) => e.model === model && e.trust !== "needs-review");
  if (!groups.length) {
    view.append(emptyState());
    return;
  }
  const best = groups.reduce((a, b) => ((a.decode ?? 0) >= (b.decode ?? 0) ? a : b));
  view.append(el("div", { class: "cards" },
    card("Macs measured", new Set(groups.map((g) => `${g.chip}/${g.memory_gb}`)).size),
    card("Results", entries.length),
    card("Fastest", `${rate(best.decode)}`, mac(best.chip, best.memory_gb))));
  view.append(el("h2", {}, "By Mac"), groupTable(groups));
  view.append(el("h2", {}, "Across TUFF versions"), versionTable(groups));
  view.append(el("h2", {}, "Every result"), entryTable(sorted(entries), false));
}

function card(label, value, detail) {
  return el("div", { class: "card" },
    el("div", { class: "label" }, label), el("div", { class: "value" }, value),
    detail ? el("div", { class: "label" }, detail) : null);
}

// A change is called only when the two versions' ranges do not overlap and
// each has more than one person; otherwise it is within the noise.
function versionTable(groups) {
  const byMac = new Map();
  for (const group of groups) {
    const key = `${group.chip}/${group.memory_gb}`;
    if (!byMac.has(key)) byMac.set(key, []);
    byMac.get(key).push(group);
  }
  const rows = [];
  for (const list of byMac.values()) {
    list.sort((a, b) => compareVersions(a.tuff, b.tuff));
    list.forEach((group, index) => {
      const previous = list[index - 1];
      let change = "–";
      let tone = null;
      if (previous && group.decode != null && previous.decode != null) {
        const percent = ((group.decode - previous.decode) / previous.decode) * 100;
        const separate = group.decode_low > previous.decode_high || group.decode_high < previous.decode_low;
        const enough = group.contributors > 1 && previous.contributors > 1;
        if (separate && enough) {
          change = `${percent > 0 ? "+" : ""}${percent.toFixed(0)}% vs ${previous.tuff}`;
          tone = percent > 0 ? "faster" : "slower";
        } else {
          change = `within noise of ${previous.tuff}`;
        }
      }
      rows.push(el("tr", {},
        el("td", {}, mac(group.chip, group.memory_gb)),
        el("td", {}, group.tuff),
        el("td", { class: "num" }, rate(group.decode)),
        el("td", { class: "num" }, rate(group.prefill)),
        el("td", { class: tone }, change),
        el("td", { class: "num" }, `${group.contributors}`)));
    });
  }
  return table([el("th", {}, "Mac"), el("th", {}, "TUFF"), el("th", { class: "num" }, "Writes"),
    el("th", { class: "num" }, "Reads prompt"), el("th", {}, "Change"), el("th", { class: "num" }, "People")], rows);
}

function renderMac(view, chip, memory) {
  const label = mac(chip, memory);
  setHeader(label, `Every model measured on ${chipShort(chip)} Macs with ${memory} GB, fastest first. Different GPU core counts and macOS versions are grouped together.`, label);
  const groups = (state.data.groups ?? []).filter((g) => g.chip === chip && g.memory_gb === memory);
  view.append(groups.length ? groupTable(sorted(groups)) : emptyState());
  const similar = [...new Set((state.data.groups ?? [])
    .filter((g) => g.memory_gb === memory && g.chip !== chip).map((g) => g.chip))];
  if (similar.length) {
    view.append(el("p", { class: "note" }, "Other chips with the same memory: ",
      similar.map((other, index) => [index ? ", " : "",
        el("a", { href: `#mac/${encode(other)}/${memory}` }, chipShort(other))])));
  }
}

function renderPost(view, number) {
  const entries = (state.data.entries ?? []).filter((e) => e.post === number);
  setHeader(`Post #${number}`, entries.length
    ? `${entries.length} model${entries.length === 1 ? "" : "s"} on ${mac(entries[0].chip, entries[0].memory_gb)} (${entries[0].mac}, macOS ${entries[0].macos}), TUFF ${entries[0].tuff}, ${entries[0].mode} run, posted by ${entries[0].author}.`
    : "This post has no accepted results.", `#${number}`);
  if (!entries.length) {
    view.append(emptyState());
    return;
  }
  view.append(entryTable(entries));
  view.append(el("p", { class: "note" },
    el("a", { href: entries[0].url, rel: "noopener" }, "Open the discussion on GitHub"),
    ". Models that failed or were skipped are listed there."));
}

// ---- start ----------------------------------------------------------------

window.addEventListener("hashchange", render);
load();
setInterval(load, REFRESH_MS);
