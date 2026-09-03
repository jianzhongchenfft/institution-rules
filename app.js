const SUPABASE_URL = "https://rdgaxgfzhraayjjwtvag.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_TTjQ16DpC1tFmyvbNlrv2Q_jVoS810J";
const SITE_URL = "https://jianzhongchenfft.github.io/institution-rules/";

const client = window.supabase.createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY
);

let currentSession = null;
let currentStaff = null;

let readerRegulations = [];
let selectedReaderId = null;

let adminRecords = [];
let selectedAdminId = null;

let editorState = {
  mode: null, // new | existing
  regulationId: null,
  versionId: null
};

const MANAGER_ROLES = ["admin", "business_manager", "organization_manager"];

const authScreen = document.getElementById("authScreen");
const unauthorizedScreen = document.getElementById("unauthorizedScreen");
const appShell = document.getElementById("appShell");
const loginBtn = document.getElementById("googleLoginBtn");
const logoutBtn = document.getElementById("logoutBtn");
const unauthorizedLogoutBtn = document.getElementById("unauthorizedLogoutBtn");
const authMessage = document.getElementById("authMessage");
const unauthorizedEmail = document.getElementById("unauthorizedEmail");
const userDisplay = document.getElementById("userDisplay");

const readerNavBtn = document.getElementById("readerNavBtn");
const adminNavBtn = document.getElementById("adminNavBtn");
const readerView = document.getElementById("readerView");
const adminView = document.getElementById("adminView");

const listEl = document.getElementById("regulationList");
const detailEl = document.getElementById("regulationDetail");
const emptyEl = document.getElementById("emptyState");
const searchEl = document.getElementById("searchInput");
const categoryEl = document.getElementById("categoryFilter");
const footerEl = document.getElementById("footerVersion");

const adminSearchInput = document.getElementById("adminSearchInput");
const adminRegulationList = document.getElementById("adminRegulationList");
const newRegulationBtn = document.getElementById("newRegulationBtn");
const adminEmptyState = document.getElementById("adminEmptyState");
const adminDetail = document.getElementById("adminDetail");
const adminTitle = document.getElementById("adminTitle");
const adminCategory = document.getElementById("adminCategory");
const createDraftBtn = document.getElementById("createDraftBtn");
const versionList = document.getElementById("versionList");
const draftNotice = document.getElementById("draftNotice");

const editorPanel = document.getElementById("editorPanel");
const editorHeading = document.getElementById("editorHeading");
const closeEditorBtn = document.getElementById("closeEditorBtn");
const regulationForm = document.getElementById("regulationForm");
const formTitle = document.getElementById("formTitle");
const formCategory = document.getElementById("formCategory");
const formVersion = document.getElementById("formVersion");
const formEffectiveDate = document.getElementById("formEffectiveDate");
const formSummary = document.getElementById("formSummary");
const formRevisionNotes = document.getElementById("formRevisionNotes");
const sectionsEditor = document.getElementById("sectionsEditor");
const addSectionBtn = document.getElementById("addSectionBtn");
const publishBtn = document.getElementById("publishBtn");
const editorMessage = document.getElementById("editorMessage");

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
  currentSession = session;

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

  currentStaff = staff;
  userDisplay.textContent = `${staff.display_name}｜${roleLabel(staff.role)}`;
  appShell.classList.remove("hidden");

  if (MANAGER_ROLES.includes(staff.role)) {
    adminNavBtn.classList.remove("hidden");
  } else {
    adminNavBtn.classList.add("hidden");
  }

  showReaderView();
  await loadReaderData();
}

function resetScreens() {
  authScreen.classList.add("hidden");
  unauthorizedScreen.classList.add("hidden");
  appShell.classList.add("hidden");
}

function showReaderView() {
  readerView.classList.remove("hidden");
  adminView.classList.add("hidden");
  readerNavBtn.classList.add("active");
  adminNavBtn.classList.remove("active");
}

async function showAdminView() {
  if (!currentStaff || !MANAGER_ROLES.includes(currentStaff.role)) return;

  readerView.classList.add("hidden");
  adminView.classList.remove("hidden");
  readerNavBtn.classList.remove("active");
  adminNavBtn.classList.add("active");
  closeEditor();
  await loadAdminData();
}

/* =========================
   Reader
========================= */

async function loadReaderData() {
  const { data, error } = await client
    .from("regulation_versions")
    .select(`
      id,
      version_label,
      effective_date,
      summary,
      content,
      revision_notes,
      status,
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
    .in("status", ["published", "superseded"])
    .order("published_at", { ascending: false });

  if (error) {
    console.error(error);
    emptyEl.textContent = "內規資料載入失敗，請聯絡管理者。";
    return;
  }

  const byRegulation = new Map();

  for (const row of data || []) {
    const reg = row.regulations;
    if (!reg?.is_active) continue;

    if (!byRegulation.has(reg.id)) {
      byRegulation.set(reg.id, {
        id: reg.id,
        title: reg.title,
        category: reg.category,
        current: null,
        history: []
      });
    }

    const target = byRegulation.get(reg.id);
    const version = normalizeVersion(row);

    if (row.status === "published" && !target.current) {
      target.current = version;
    } else {
      target.history.push(version);
    }
  }

  readerRegulations = [...byRegulation.values()]
    .filter(x => x.current)
    .sort((a, b) => a.title.localeCompare(b.title, "zh-Hant"));

  populateReaderCategories();
  renderReaderList();
  updateFooter();

  if (readerRegulations.length > 0) {
    if (!readerRegulations.some(x => x.id === selectedReaderId)) {
      selectedReaderId = readerRegulations[0].id;
    }
    selectReaderRegulation(selectedReaderId);
  } else {
    detailEl.classList.add("hidden");
    emptyEl.classList.remove("hidden");
    emptyEl.textContent = "目前沒有已發布的內規。";
  }
}

function normalizeVersion(row) {
  return {
    id: row.id,
    version: row.version_label,
    effectiveDate: formatDateROC(row.effective_date),
    publishedDate: formatDateROC(row.published_at),
    summary: row.summary || "",
    revisionNotes: row.revision_notes || "",
    content: Array.isArray(row.content) ? row.content : [],
    status: row.status
  };
}

function populateReaderCategories() {
  categoryEl.innerHTML = '<option value="">全部類別</option>';
  const categories = [...new Set(readerRegulations.map(x => x.category))].sort();

  categories.forEach(category => {
    const option = document.createElement("option");
    option.value = category;
    option.textContent = category;
    categoryEl.appendChild(option);
  });
}

function renderReaderList() {
  const keyword = searchEl.value.trim().toLowerCase();
  const category = categoryEl.value;

  const filtered = readerRegulations.filter(item => {
    const current = item.current;

    const searchable = [
      item.title,
      item.category,
      current.summary,
      ...current.content.map(section =>
        `${section.heading || ""} ${section.text || ""}`
      )
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
    button.className =
      "regulation-item" + (item.id === selectedReaderId ? " active" : "");

    button.innerHTML = `
      <strong>${escapeHtml(item.title)}</strong>
      <small>${escapeHtml(item.category)}｜版本 ${escapeHtml(item.current.version)}</small>
    `;

    button.addEventListener("click", () => selectReaderRegulation(item.id));
    listEl.appendChild(button);
  });
}

function selectReaderRegulation(id) {
  selectedReaderId = id;
  const item = readerRegulations.find(x => x.id === id);
  if (!item?.current) return;

  const current = item.current;

  emptyEl.classList.add("hidden");
  detailEl.classList.remove("hidden");

  const historyHtml = item.history.length
    ? `
      <details class="history-block">
        <summary>歷史版本（${item.history.length}）</summary>
        ${item.history.map(v => `
          <div class="history-item">
            <strong>版本 ${escapeHtml(v.version)}｜生效日 ${escapeHtml(v.effectiveDate)}</strong>
            <p>${escapeHtml(v.revisionNotes || "無修訂說明")}</p>
          </div>
        `).join("")}
      </details>
    `
    : "";

  detailEl.innerHTML = `
    <h2>${escapeHtml(item.title)}</h2>
    <div class="meta">
      <span>類別：${escapeHtml(item.category)}</span>
      <span>版本：${escapeHtml(current.version)}</span>
      <span>生效日：${escapeHtml(current.effectiveDate)}</span>
      <span>發布日：${escapeHtml(current.publishedDate)}</span>
    </div>
    <div class="summary">${escapeHtml(current.summary)}</div>
    ${current.content.map(section => `
      <section class="section">
        <h3>${escapeHtml(section.heading || "")}</h3>
        <p>${escapeHtml(section.text || "")}</p>
      </section>
    `).join("")}
    ${historyHtml}
  `;

  renderReaderList();
}

function updateFooter() {
  footerEl.textContent = `目前共 ${readerRegulations.length} 份已發布內規`;
}

/* =========================
   Admin
========================= */

async function loadAdminData() {
  const { data: regs, error: regError } = await client
    .from("regulations")
    .select("id,slug,title,category,is_active,created_at,updated_at")
    .order("title", { ascending: true });

  if (regError) {
    console.error(regError);
    adminRegulationList.innerHTML =
      '<div class="empty-state">管理資料載入失敗。</div>';
    return;
  }

  const { data: versions, error: versionError } = await client
    .from("regulation_versions")
    .select("id,regulation_id,version_label,effective_date,summary,content,revision_notes,status,published_at,created_by,created_at")
    .order("created_at", { ascending: false });

  if (versionError) {
    console.error(versionError);
    adminRegulationList.innerHTML =
      '<div class="empty-state">版本資料載入失敗。</div>';
    return;
  }

  const versionMap = new Map();

  for (const v of versions || []) {
    if (!versionMap.has(v.regulation_id)) versionMap.set(v.regulation_id, []);
    versionMap.get(v.regulation_id).push(v);
  }

  adminRecords = (regs || []).map(reg => ({
    ...reg,
    versions: versionMap.get(reg.id) || []
  }));

  renderAdminList();

  if (selectedAdminId && adminRecords.some(x => x.id === selectedAdminId)) {
    selectAdminRegulation(selectedAdminId);
  } else {
    selectedAdminId = null;
    adminDetail.classList.add("hidden");
    adminEmptyState.classList.remove("hidden");
  }
}

function renderAdminList() {
  const keyword = adminSearchInput.value.trim().toLowerCase();

  const filtered = adminRecords.filter(item => {
    return !keyword ||
      `${item.title} ${item.category}`.toLowerCase().includes(keyword);
  });

  adminRegulationList.innerHTML = "";

  if (filtered.length === 0) {
    adminRegulationList.innerHTML =
      '<div class="empty-state">找不到符合條件的內規。</div>';
    return;
  }

  filtered.forEach(item => {
    const current = item.versions.find(v => v.status === "published");
    const draft = item.versions.find(v => v.status === "draft");

    const btn = document.createElement("button");
    btn.className =
      "admin-regulation-item" + (item.id === selectedAdminId ? " active" : "");

    btn.innerHTML = `
      <strong>${escapeHtml(item.title)}</strong>
      <small>${escapeHtml(item.category)}</small>
      <div>
        ${current ? `<span class="badge">現行 ${escapeHtml(current.version_label)}</span>` : ""}
        ${draft ? `<span class="badge draft">有草稿 ${escapeHtml(draft.version_label)}</span>` : ""}
      </div>
    `;

    btn.addEventListener("click", () => selectAdminRegulation(item.id));
    adminRegulationList.appendChild(btn);
  });
}

function selectAdminRegulation(id) {
  selectedAdminId = id;
  const item = adminRecords.find(x => x.id === id);
  if (!item) return;

  closeEditor();

  adminEmptyState.classList.add("hidden");
  adminDetail.classList.remove("hidden");

  adminTitle.textContent = item.title;
  adminCategory.textContent = item.category;

  const draft = item.versions.find(v => v.status === "draft");
  const published = item.versions.find(v => v.status === "published");

  if (draft) {
    draftNotice.classList.remove("hidden");
    draftNotice.textContent =
      `此內規目前已有草稿版本 ${draft.version_label}。請先編輯或發布該草稿。`;
    createDraftBtn.disabled = true;
  } else {
    draftNotice.classList.add("hidden");
    draftNotice.textContent = "";
    createDraftBtn.disabled = false;
  }

  if (!published && !draft) {
    createDraftBtn.textContent = "建立第一版草稿";
  } else {
    createDraftBtn.textContent = "建立新版草稿";
  }

  renderVersionList(item);
  renderAdminList();
}

function renderVersionList(item) {
  const versions = [...item.versions].sort((a, b) =>
    new Date(b.created_at) - new Date(a.created_at)
  );

  if (versions.length === 0) {
    versionList.innerHTML = '<p class="empty-state">尚無版本紀錄。</p>';
    return;
  }

  versionList.innerHTML = versions.map(v => {
    const statusText = {
      draft: "草稿",
      published: "現行版本",
      superseded: "歷史版本"
    }[v.status] || v.status;

    const statusClass = `status-${v.status}`;

    return `
      <div class="version-row">
        <div>
          <strong>版本 ${escapeHtml(v.version_label)}　
            <span class="${statusClass}">${escapeHtml(statusText)}</span>
          </strong>
          <p>生效日：${escapeHtml(formatDateROC(v.effective_date))}　
             建立日：${escapeHtml(formatDateROC(v.created_at))}</p>
          <p>${escapeHtml(v.revision_notes || "無修訂說明")}</p>
        </div>
        <div class="version-actions">
          ${v.status === "draft"
            ? `<button class="secondary-button edit-draft-btn" data-version-id="${v.id}" type="button">編輯草稿</button>`
            : ""}
        </div>
      </div>
    `;
  }).join("");

  document.querySelectorAll(".edit-draft-btn").forEach(btn => {
    btn.addEventListener("click", () => openExistingDraft(btn.dataset.versionId));
  });
}

function openNewRegulationEditor() {
  editorState = {
    mode: "new",
    regulationId: null,
    versionId: null
  };

  editorHeading.textContent = "新增內規";
  regulationForm.reset();
  sectionsEditor.innerHTML = "";
  addSection("", "");
  formEffectiveDate.value = todayISO();
  clearEditorMessage();

  adminDetail.classList.add("hidden");
  adminEmptyState.classList.add("hidden");
  editorPanel.classList.remove("hidden");
}

function openNewDraftEditor() {
  const item = adminRecords.find(x => x.id === selectedAdminId);
  if (!item) return;

  const existingDraft = item.versions.find(v => v.status === "draft");
  if (existingDraft) {
    openExistingDraft(existingDraft.id);
    return;
  }

  const published = item.versions.find(v => v.status === "published");

  editorState = {
    mode: "existing",
    regulationId: item.id,
    versionId: null
  };

  editorHeading.textContent = `建立新版草稿｜${item.title}`;
  regulationForm.reset();
  formTitle.value = item.title;
  formCategory.value = item.category;
  formEffectiveDate.value = todayISO();
  formSummary.value = published?.summary || "";
  formRevisionNotes.value = "";
  formVersion.value = suggestNextVersion(published?.version_label || "");

  sectionsEditor.innerHTML = "";
  const sections = Array.isArray(published?.content) ? published.content : [];

  if (sections.length) {
    sections.forEach(s => addSection(s.heading || "", s.text || ""));
  } else {
    addSection("", "");
  }

  clearEditorMessage();
  adminDetail.classList.add("hidden");
  adminEmptyState.classList.add("hidden");
  editorPanel.classList.remove("hidden");
}

function openExistingDraft(versionId) {
  const item = adminRecords.find(x =>
    x.versions.some(v => v.id === versionId)
  );

  if (!item) return;

  const draft = item.versions.find(v => v.id === versionId);
  if (!draft || draft.status !== "draft") return;

  selectedAdminId = item.id;

  editorState = {
    mode: "existing",
    regulationId: item.id,
    versionId: draft.id
  };

  editorHeading.textContent = `編輯草稿｜${item.title}`;
  formTitle.value = item.title;
  formCategory.value = item.category;
  formVersion.value = draft.version_label;
  formEffectiveDate.value = draft.effective_date || todayISO();
  formSummary.value = draft.summary || "";
  formRevisionNotes.value = draft.revision_notes || "";

  sectionsEditor.innerHTML = "";

  const sections = Array.isArray(draft.content) ? draft.content : [];
  if (sections.length) {
    sections.forEach(s => addSection(s.heading || "", s.text || ""));
  } else {
    addSection("", "");
  }

  clearEditorMessage();
  adminDetail.classList.add("hidden");
  adminEmptyState.classList.add("hidden");
  editorPanel.classList.remove("hidden");
}

function closeEditor() {
  editorPanel.classList.add("hidden");
  clearEditorMessage();

  if (selectedAdminId && adminRecords.some(x => x.id === selectedAdminId)) {
    adminEmptyState.classList.add("hidden");
    adminDetail.classList.remove("hidden");
  } else {
    adminDetail.classList.add("hidden");
    adminEmptyState.classList.remove("hidden");
  }
}

function addSection(heading = "", text = "") {
  const wrapper = document.createElement("div");
  wrapper.className = "section-editor";

  wrapper.innerHTML = `
    <div class="section-editor-head">
      <strong>段落</strong>
      <button class="remove-section" type="button">移除</button>
    </div>
    <input class="section-heading-input" placeholder="段落標題，例如：一、目的" value="${escapeAttribute(heading)}" />
    <textarea class="section-text-input" placeholder="段落本文">${escapeHtml(text)}</textarea>
  `;

  wrapper.querySelector(".remove-section").addEventListener("click", () => {
    wrapper.remove();
    renumberSections();
  });

  sectionsEditor.appendChild(wrapper);
  renumberSections();
}

function renumberSections() {
  [...sectionsEditor.querySelectorAll(".section-editor")].forEach((node, index) => {
    const label = node.querySelector(".section-editor-head strong");
    label.textContent = `段落 ${index + 1}`;
  });
}

function collectSections() {
  return [...sectionsEditor.querySelectorAll(".section-editor")]
    .map(node => ({
      heading: node.querySelector(".section-heading-input").value.trim(),
      text: node.querySelector(".section-text-input").value.trim()
    }))
    .filter(s => s.heading || s.text);
}

async function saveDraft() {
  if (!regulationForm.reportValidity()) return null;

  const sections = collectSections();
  if (sections.length === 0) {
    setEditorMessage("請至少填寫一個內規段落。", true);
    return null;
  }

  setEditorMessage("正在儲存…");

  const title = formTitle.value.trim();
  const category = formCategory.value.trim();
  const versionLabel = formVersion.value.trim();
  const effectiveDate = formEffectiveDate.value;
  const summary = formSummary.value.trim();
  const revisionNotes = formRevisionNotes.value.trim();

  let regulationId = editorState.regulationId;

  if (editorState.mode === "new" && !regulationId) {
    const { data: newReg, error: regInsertError } = await client
      .from("regulations")
      .insert({
        slug: `rule-${Date.now()}`,
        title,
        category,
        is_active: true
      })
      .select("id")
      .single();

    if (regInsertError) {
      console.error(regInsertError);
      setEditorMessage(explainSaveError(regInsertError), true);
      return null;
    }

    regulationId = newReg.id;
    editorState.regulationId = regulationId;
    editorState.mode = "existing";
    selectedAdminId = regulationId;
  } else {
    const { error: regUpdateError } = await client
      .from("regulations")
      .update({
        title,
        category,
        updated_at: new Date().toISOString()
      })
      .eq("id", regulationId);

    if (regUpdateError) {
      console.error(regUpdateError);
      setEditorMessage(explainSaveError(regUpdateError), true);
      return null;
    }
  }

  const versionPayload = {
    regulation_id: regulationId,
    version_label: versionLabel,
    effective_date: effectiveDate,
    summary,
    content: sections,
    revision_notes: revisionNotes,
    status: "draft",
    created_by: currentSession.user.id
  };

  if (editorState.versionId) {
    const { error } = await client
      .from("regulation_versions")
      .update({
        version_label: versionLabel,
        effective_date: effectiveDate,
        summary,
        content: sections,
        revision_notes: revisionNotes
      })
      .eq("id", editorState.versionId);

    if (error) {
      console.error(error);
      setEditorMessage(explainSaveError(error), true);
      return null;
    }
  } else {
    const { data: newVersion, error } = await client
      .from("regulation_versions")
      .insert(versionPayload)
      .select("id")
      .single();

    if (error) {
      console.error(error);
      setEditorMessage(explainSaveError(error), true);
      return null;
    }

    editorState.versionId = newVersion.id;
  }

  setEditorMessage("草稿已儲存。", false);
  await loadAdminData();

  // Keep editor open after reload.
  openExistingDraft(editorState.versionId);
  setEditorMessage("草稿已儲存。", false);

  return editorState.versionId;
}

async function publishCurrentDraft() {
  const versionId = await saveDraft();
  if (!versionId) return;

  const versionLabel = formVersion.value.trim();

  const confirmed = window.confirm(
    `確定要發布版本 ${versionLabel} 嗎？\n\n發布後，員工會立即看到這個版本；原本的正式版本會保留為歷史版本。`
  );

  if (!confirmed) return;

  setEditorMessage("正在發布…");

  const { error } = await client.rpc("publish_regulation_version", {
    p_version_id: versionId
  });

  if (error) {
    console.error(error);
    setEditorMessage(`發布失敗：${error.message}`, true);
    return;
  }

  setEditorMessage("發布成功。", false);

  await Promise.all([
    loadAdminData(),
    loadReaderData()
  ]);

  closeEditor();

  if (selectedAdminId) {
    selectAdminRegulation(selectedAdminId);
  }

  window.alert(`版本 ${versionLabel} 已正式發布。`);
}

function setEditorMessage(message, isError = false) {
  editorMessage.textContent = message;
  editorMessage.className =
    "editor-message " + (isError ? "error" : "success");
}

function clearEditorMessage() {
  editorMessage.textContent = "";
  editorMessage.className = "editor-message";
}

function explainSaveError(error) {
  const msg = error?.message || "未知錯誤";

  if (msg.includes("regulation_versions_regulation_id_version_label_key") ||
      msg.includes("duplicate key")) {
    return "這個版本號已經使用過，請改用新的版本號。";
  }

  if (msg.includes("row-level security")) {
    return "你的帳號沒有這項修改權限。";
  }

  return `儲存失敗：${msg}`;
}

/* =========================
   Helpers / Events
========================= */

function roleLabel(role) {
  return {
    care_worker: "居服員",
    supervisor: "督導",
    business_manager: "業務負責人",
    organization_manager: "機構負責人",
    admin: "管理員"
  }[role] || role;
}

function formatDateROC(value) {
  if (!value) return "—";

  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return String(value);

  const rocYear = d.getFullYear() - 1911;
  return `${rocYear}/${String(d.getMonth() + 1).padStart(2, "0")}/${String(d.getDate()).padStart(2, "0")}`;
}

function todayISO() {
  const d = new Date();
  const local = new Date(d.getTime() - d.getTimezoneOffset() * 60000);
  return local.toISOString().slice(0, 10);
}

function suggestNextVersion(current) {
  const match = /^(\d+)(?:\.(\d+))?$/.exec(current || "");
  if (!match) return "";

  const major = Number(match[1]);
  const minor = Number(match[2] || 0);
  return `${major}.${minor + 1}`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function escapeAttribute(value) {
  return escapeHtml(value).replaceAll("`", "&#096;");
}

loginBtn.addEventListener("click", signInWithGoogle);
logoutBtn.addEventListener("click", signOut);
unauthorizedLogoutBtn.addEventListener("click", signOut);

readerNavBtn.addEventListener("click", showReaderView);
adminNavBtn.addEventListener("click", showAdminView);

searchEl.addEventListener("input", renderReaderList);
categoryEl.addEventListener("change", renderReaderList);

adminSearchInput.addEventListener("input", renderAdminList);
newRegulationBtn.addEventListener("click", openNewRegulationEditor);
createDraftBtn.addEventListener("click", openNewDraftEditor);
closeEditorBtn.addEventListener("click", closeEditor);
addSectionBtn.addEventListener("click", () => addSection("", ""));

regulationForm.addEventListener("submit", async event => {
  event.preventDefault();
  await saveDraft();
});

publishBtn.addEventListener("click", publishCurrentDraft);

client.auth.onAuthStateChange((_event, session) => {
  checkAccess(session);
});

client.auth.getSession().then(({ data }) => {
  checkAccess(data.session);
});
