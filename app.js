let regulations = [];
let selectedId = null;

const listEl = document.getElementById("regulationList");
const detailEl = document.getElementById("regulationDetail");
const emptyEl = document.getElementById("emptyState");
const searchEl = document.getElementById("searchInput");
const categoryEl = document.getElementById("categoryFilter");
const footerEl = document.getElementById("footerVersion");

async function loadData() {
  const response = await fetch("data/regulations.json", { cache: "no-store" });
  if (!response.ok) throw new Error("無法載入內規資料");
  regulations = await response.json();

  const categories = [...new Set(regulations.map(x => x.category))].sort();
  categories.forEach(category => {
    const option = document.createElement("option");
    option.value = category;
    option.textContent = category;
    categoryEl.appendChild(option);
  });

  renderList();
  updateFooter();

  if (regulations.length > 0) selectRegulation(regulations[0].id);
}

function renderList() {
  const keyword = searchEl.value.trim().toLowerCase();
  const category = categoryEl.value;

  const filtered = regulations.filter(item => {
    const searchable = [
      item.title,
      item.category,
      item.summary,
      ...item.content.map(section => section.heading + " " + section.text)
    ].join(" ").toLowerCase();

    const matchesKeyword = !keyword || searchable.includes(keyword);
    const matchesCategory = !category || item.category === category;
    return matchesKeyword && matchesCategory;
  });

  listEl.innerHTML = "";

  if (filtered.length === 0) {
    listEl.innerHTML = '<div class="empty-state">找不到符合條件的內規。</div>';
    return;
  }

  filtered.forEach(item => {
    const button = document.createElement("button");
    button.className = "regulation-item" + (item.id === selectedId ? " active" : "");
    button.innerHTML = `
      <strong>${escapeHtml(item.title)}</strong>
      <small>${escapeHtml(item.category)}｜版本 ${escapeHtml(item.version)}</small>
    `;
    button.addEventListener("click", () => selectRegulation(item.id));
    listEl.appendChild(button);
  });
}

function selectRegulation(id) {
  selectedId = id;
  const item = regulations.find(x => x.id === id);
  if (!item) return;

  emptyEl.classList.add("hidden");
  detailEl.classList.remove("hidden");

  detailEl.innerHTML = `
    <h2>${escapeHtml(item.title)}</h2>
    <div class="meta">
      <span>類別：${escapeHtml(item.category)}</span>
      <span>版本：${escapeHtml(item.version)}</span>
      <span>生效日：${escapeHtml(item.effectiveDate)}</span>
      <span>更新日：${escapeHtml(item.updatedAt)}</span>
    </div>
    <div class="summary">${escapeHtml(item.summary)}</div>
    ${item.content.map(section => `
      <section class="section">
        <h3>${escapeHtml(section.heading)}</h3>
        <p>${escapeHtml(section.text)}</p>
      </section>
    `).join("")}
  `;

  renderList();
}

function updateFooter() {
  if (!regulations.length) return;
  const latest = regulations
    .map(x => x.updatedAt)
    .sort()
    .slice(-1)[0];
  footerEl.textContent = `目前共 ${regulations.length} 份內規｜資料更新：${latest}`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

searchEl.addEventListener("input", renderList);
categoryEl.addEventListener("change", renderList);

loadData().catch(error => {
  console.error(error);
  emptyEl.textContent = "載入失敗。請確認網站檔案是否完整。";
});
