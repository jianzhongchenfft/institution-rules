const SUPABASE_URL = "https://rdgaxgfzhraayjjwtvag.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_TTjQ16DpC1tFmyvbNlrv2Q_jVoS810J";
const SITE_URL = "https://jianzhongchenfft.github.io/institution-rules/";

const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY);

let regulations = [];
let selectedId = null;

const authScreen = document.getElementById("authScreen");
const unauthorizedScreen = document.getElementById("unauthorizedScreen");
const appShell = document.getElementById("appShell");
const loginBtn = document.getElementById("googleLoginBtn");
const logoutBtn = document.getElementById("logoutBtn");
const unauthorizedLogoutBtn = document.getElementById("unauthorizedLogoutBtn");
const authMessage = document.getElementById("authMessage");
const unauthorizedEmail = document.getElementById("unauthorizedEmail");
const userDisplay = document.getElementById("userDisplay");

const listEl = document.getElementById("regulationList");
const detailEl = document.getElementById("regulationDetail");
const emptyEl = document.getElementById("emptyState");
const searchEl = document.getElementById("searchInput");
const categoryEl = document.getElementById("categoryFilter");
const footerEl = document.getElementById("footerVersion");

async function signInWithGoogle() {
  authMessage.textContent = "正在前往 Google 登入…";
  const { error } = await client.auth.signInWithOAuth({
    provider: "google",
    options: { redirectTo: SITE_URL }
  });
  if (error) {
    console.error(error);
    authMessage.textContent = "登入失敗，請稍後再試。";
  }
}

async function signOut() {
  await client.auth.signOut();
  window.location.href = SITE_URL;
}

async function checkAccess(session) {
  resetScreens();

  if (!session?.user) {
    authScreen.classList.remove("hidden");
    return;
  }

  const email = session.user.email || "";
  const { data: staff, error } = await client
    .from("staff_users")
    .select("display_name,email,role,is_active")
    .eq("email", email)
    .eq("is_active", true)
    .maybeSingle();

  if (error) {
    console.error(error);
    authScreen.classList.remove("hidden");
    authMessage.textContent = "權限檢查失敗，請稍後再試。";
    return;
  }

  if (!staff) {
    unauthorizedEmail.textContent = email;
    unauthorizedScreen.classList.remove("hidden");
    return;
  }

  userDisplay.textContent = `${staff.display_name}｜${roleLabel(staff.role)}`;
  appShell.classList.remove("hidden");
  await loadData();
}

function resetScreens() {
  authScreen.classList.add("hidden");
  unauthorizedScreen.classList.add("hidden");
  appShell.classList.add("hidden");
}

async function loadData() {
  const { data, error } = await client
    .from("regulation_versions")
    .select(`
      id,
      version_label,
      effective_date,
      summary,
      content,
      published_at,
      regulation_id,
      regulations!inner (
        id,
        slug,
        title,
        category,
        is_active
      )
    `)
    .eq("status", "published")
    .order("published_at", { ascending: false });

  if (error) {
    console.error(error);
    emptyEl.textContent = "內規資料載入失敗，請聯絡管理者。";
    return;
  }

  const seen = new Set();
  regulations = [];

  for (const row of data || []) {
    const reg = row.regulations;
    if (!reg || seen.has(reg.id)) continue;
    seen.add(reg.id);
    regulations.push({
      id: reg.id,
      title: reg.title,
      category: reg.category,
      version: row.version_label,
      effectiveDate: formatDate(row.effective_date),
      updatedAt: formatDate(row.published_at),
      summary: row.summary || "",
      content: Array.isArray(row.content) ? row.content : []
    });
  }

  populateCategories();
  renderList();
  updateFooter();

  if (regulations.length > 0) {
    selectRegulation(regulations[0].id);
  } else {
    emptyEl.textContent = "目前沒有已發布的內規。";
  }
}

function populateCategories() {
  categoryEl.innerHTML = '<option value="">全部類別</option>';
  const categories = [...new Set(regulations.map(x => x.category))].sort();
  categories.forEach(category => {
    const option = document.createElement("option");
    option.value = category;
    option.textContent = category;
    categoryEl.appendChild(option);
  });
}

function renderList() {
  const keyword = searchEl.value.trim().toLowerCase();
  const category = categoryEl.value;

  const filtered = regulations.filter(item => {
    const searchable = [
      item.title,
      item.category,
      item.summary,
      ...item.content.map(section => `${section.heading || ""} ${section.text || ""}`)
    ].join(" ").toLowerCase();

    return (!keyword || searchable.includes(keyword)) &&
           (!category || item.category === category);
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
      <span>發布日：${escapeHtml(item.updatedAt)}</span>
    </div>
    <div class="summary">${escapeHtml(item.summary)}</div>
    ${item.content.map(section => `
      <section class="section">
        <h3>${escapeHtml(section.heading || "")}</h3>
        <p>${escapeHtml(section.text || "")}</p>
      </section>
    `).join("")}
  `;

  renderList();
}

function updateFooter() {
  footerEl.textContent = `目前共 ${regulations.length} 份已發布內規`;
}

function formatDate(value) {
  if (!value) return "—";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return value;
  return `${d.getFullYear()}/${String(d.getMonth()+1).padStart(2,"0")}/${String(d.getDate()).padStart(2,"0")}`;
}

function roleLabel(role) {
  return {
    care_worker: "居服員",
    supervisor: "督導",
    business_manager: "業務負責人",
    organization_manager: "機構負責人",
    admin: "管理員"
  }[role] || role;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

loginBtn.addEventListener("click", signInWithGoogle);
logoutBtn.addEventListener("click", signOut);
unauthorizedLogoutBtn.addEventListener("click", signOut);
searchEl.addEventListener("input", renderList);
categoryEl.addEventListener("change", renderList);

client.auth.onAuthStateChange((_event, session) => {
  checkAccess(session);
});

client.auth.getSession().then(({ data }) => {
  checkAccess(data.session);
});
