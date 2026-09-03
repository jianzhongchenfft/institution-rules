const SUPABASE_URL = "https://rdgaxgfzhraayjjwtvag.supabase.co";
const SUPABASE_PUBLISHABLE_KEY = "sb_publishable_TTjQ16DpC1tFmyvbNlrv2Q_jVoS810J";
const SITE_URL = "https://jianzhongchenfft.github.io/institution-rules/";
const FILE_BUCKET = "regulation-files";

const client = window.supabase.createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY
);

const MANAGER_ROLES = ["admin", "business_manager", "organization_manager"];
const MAX_FILE_SIZE = 25 * 1024 * 1024;
const ALLOWED_EXTENSIONS = ["pdf", "doc", "docx"];

let currentSession = null;
let currentStaff = null;

let readerRegulations = [];
let selectedReaderId = null;

let adminRecords = [];
let selectedAdminId = null;

let editorState = {
  mode: null,
  regulationId: null,
  versionId: null,
  existingFilePath: null,
  existingFileName: null
};

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
const formRevisionNotes = document.getElementById("formRevisionNotes");
const formFile = document.getElementById("formFile");
const currentFileInfo = document.getElementById("currentFileInfo");
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

/* Reader */

async function loadReaderData() {
  const { data, error } = await client
    .from("regulation_versions")
    .select(`
      id,
      version_label,
      effective_date,
      revision_notes,
      status,
      published_at,
      regulation_id,
      file_path,
      file_name,
      file_mime_type,
      file_size,
      regulations!inner (
        id,
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

  const map = new Map();

  for (const row of data || []) {
    const reg = row.regulations;
    if (!reg?.is_active) continue;

    if (!map.has(reg.id)) {
      map.set(reg.id, {
        id: reg.id,
        title: reg.title,
        category: reg.category,
        current: null,
        history: []
      });
    }

    const version = normalizeVersion(row);
    const target = map.get(reg.id);

    if (row.status === "published" && !target.current) {
      target.current = version;
    } else {
      target.history.push(version);
    }
  }

  readerRegulations = [...map.values()]
    .filter(item => item.current)
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
    revisionNotes: row.revision_notes || "",
    status: row.status,
    filePath: row.file_path,
    fileName: row.file_name,
    fileMimeType: row.file_mime_type,
    fileSize: row.file_size
  };
}

function populateReaderCategories() {
  categoryEl.innerHTML = '<option value="">全部類別</option>';

  const categories = [...new Set(readerRegulations.map(x => x.category))].sort();

  for (const category of categories) {
    const option = document.createElement("option");
    option.value = category;
    option.textContent = category;
    categoryEl.appendChild(option);
  }
}

function renderReaderList() {
  const keyword = searchEl.value.trim().toLowerCase();
  const category = categoryEl.value;

  const filtered = readerRegulations.filter(item => {
    const searchable = `${item.title} ${item.category}`.toLowerCase();
    return (!keyword || searchable.includes(keyword)) &&
           (!category || item.category === category);
  });

  listEl.innerHTML = "";

  if (!filtered.length) {
    listEl.innerHTML = '<div class="empty-state">找不到符合條件的內規。</div>';
    return;
  }

  for (const item of filtered) {
    const button = document.createElement("button");
    button.className =
      "regulation-item" + (item.id === selectedReaderId ? " active" : "");

    button.innerHTML = `
      <strong>${escapeHtml(item.title)}</strong>
      <small>${escapeHtml(item.category)}｜版本 ${escapeHtml(item.current.version)}</small>
    `;

    button.addEventListener("click", () => selectReaderRegulation(item.id));
    listEl.appendChild(button);
  }
}

function selectReaderRegulation(id) {
  selectedReaderId = id;
  const item = readerRegulations.find(x => x.id === id);
  if (!item?.current) return;

  const current = item.current;

  emptyEl.classList.add("hidden");
  detailEl.classList.remove("hidden");

  const currentFileHtml = current.filePath
    ? `
      <div class="file-panel">
        <h3>正式內規檔案</h3>
        <p>${escapeHtml(current.fileName || "內規檔案")}</p>
        <p>${escapeHtml(formatFileSize(current.fileSize))}</p>
        <button class="download-button current-download-btn" type="button">下載檔案</button>
      </div>
    `
    : `
      <div class="file-panel">
        <h3>正式內規檔案</h3>
        <p>此版本為舊系統建立，尚未附加原始檔案。</p>
      </div>
    `;

  const historyHtml = item.history.length
    ? `
      <details class="history-block">
        <summary>歷史版本（${item.history.length}）</summary>
        ${item.history.map(v => `
          <div class="history-item">
            <div class="history-item-head">
              <div>
                <strong>版本 ${escapeHtml(v.version)}｜生效日 ${escapeHtml(v.effectiveDate)}</strong>
                <p>${escapeHtml(v.revisionNotes || "無修訂說明")}</p>
                <p>${escapeHtml(v.fileName || "此歷史版本尚未附檔")}</p>
              </div>
              ${v.filePath
                ? `<button class="download-button history-download-btn" data-version-id="${v.id}" type="button">下載</button>`
                : ""}
            </div>
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
    ${current.revisionNotes
      ? `<div class="revision-note"><strong>修訂說明：</strong>${escapeHtml(current.revisionNotes)}</div>`
      : ""}
    ${currentFileHtml}
    ${historyHtml}
  `;

  const currentBtn = detailEl.querySelector(".current-download-btn");
  if (currentBtn) {
    currentBtn.addEventListener("click", () =>
      downloadRegulationFile(current.filePath, current.fileName)
    );
  }

  detailEl.querySelectorAll(".history-download-btn").forEach(btn => {
    const versionId = btn.dataset.versionId;
    const version = item.history.find(v => v.id === versionId);
    btn.addEventListener("click", () =>
      downloadRegulationFile(version.filePath, version.fileName)
    );
  });

  renderReaderList();
}

function updateFooter() {
  footerEl.textContent = `目前共 ${readerRegulations.length} 份已發布內規`;
}

/* Admin */

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
    .select(`
      id,
      regulation_id,
      version_label,
      effective_date,
      revision_notes,
      status,
      published_at,
      created_by,
      created_at,
      file_path,
      file_name,
      file_mime_type,
      file_size
    `)
    .order("created_at", { ascending: false });

  if (versionError) {
    console.error(versionError);
    adminRegulationList.innerHTML =
      '<div class="empty-state">版本資料載入失敗。</div>';
    return;
  }

  const versionMap = new Map();

  for (const version of versions || []) {
    if (!versionMap.has(version.regulation_id)) {
      versionMap.set(version.regulation_id, []);
    }
    versionMap.get(version.regulation_id).push(version);
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

  const filtered = adminRecords.filter(item =>
    !keyword ||
    `${item.title} ${item.category}`.toLowerCase().includes(keyword)
  );

  adminRegulationList.innerHTML = "";

  if (!filtered.length) {
    adminRegulationList.innerHTML =
      '<div class="empty-state">找不到符合條件的內規。</div>';
    return;
  }

  for (const item of filtered) {
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
  }
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

  if (draft) {
    draftNotice.classList.remove("hidden");
    draftNotice.textContent =
      `目前已有草稿版本 ${draft.version_label}。請先編輯或發布該草稿。`;
    createDraftBtn.disabled = true;
  } else {
    draftNotice.classList.add("hidden");
    draftNotice.textContent = "";
    createDraftBtn.disabled = false;
  }

  renderVersionList(item);
  renderAdminList();
}

function renderVersionList(item) {
  const versions = [...item.versions].sort(
    (a, b) => new Date(b.created_at) - new Date(a.created_at)
  );

  if (!versions.length) {
    versionList.innerHTML = '<p class="empty-state">尚無版本紀錄。</p>';
    return;
  }

  versionList.innerHTML = versions.map(v => {
    const statusText = {
      draft: "草稿",
      published: "現行版本",
      superseded: "歷史版本"
    }[v.status] || v.status;

    return `
      <div class="version-row">
        <div>
          <strong>
            版本 ${escapeHtml(v.version_label)}　
            <span class="status-${escapeHtml(v.status)}">${escapeHtml(statusText)}</span>
          </strong>
          <p>生效日：${escapeHtml(formatDateROC(v.effective_date))}　
             建立日：${escapeHtml(formatDateROC(v.created_at))}</p>
          <p>${escapeHtml(v.file_name || "尚未附加檔案")}</p>
          <p>${escapeHtml(v.revision_notes || "無修訂說明")}</p>
        </div>
        <div class="version-actions">
          ${v.file_path
            ? `<button class="secondary-button admin-download-btn" data-version-id="${v.id}" type="button">下載檔案</button>`
            : ""}
          ${v.status === "draft"
            ? `<button class="secondary-button edit-draft-btn" data-version-id="${v.id}" type="button">編輯草稿</button>`
            : ""}
        </div>
      </div>
    `;
  }).join("");

  versionList.querySelectorAll(".admin-download-btn").forEach(btn => {
    const version = item.versions.find(v => v.id === btn.dataset.versionId);
    btn.addEventListener("click", () =>
      downloadRegulationFile(version.file_path, version.file_name)
    );
  });

  versionList.querySelectorAll(".edit-draft-btn").forEach(btn => {
    btn.addEventListener("click", () =>
      openExistingDraft(btn.dataset.versionId)
    );
  });
}

function openNewRegulationEditor() {
  editorState = {
    mode: "new",
    regulationId: null,
    versionId: null,
    existingFilePath: null,
    existingFileName: null
  };

  editorHeading.textContent = "新增內規";
  regulationForm.reset();
  formVersion.value = "1.0";
  formEffectiveDate.value = todayISO();
  currentFileInfo.classList.add("hidden");
  currentFileInfo.textContent = "";
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
    versionId: null,
    existingFilePath: null,
    existingFileName: null
  };

  editorHeading.textContent = `上傳新版｜${item.title}`;
  regulationForm.reset();
  formTitle.value = item.title;
  formCategory.value = item.category;
  formVersion.value = suggestNextVersion(published?.version_label || "");
  formEffectiveDate.value = todayISO();
  formRevisionNotes.value = "";
  currentFileInfo.classList.add("hidden");
  currentFileInfo.textContent = "";
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
    versionId: draft.id,
    existingFilePath: draft.file_path,
    existingFileName: draft.file_name
  };

  editorHeading.textContent = `編輯草稿｜${item.title}`;
  regulationForm.reset();
  formTitle.value = item.title;
  formCategory.value = item.category;
  formVersion.value = draft.version_label;
  formEffectiveDate.value = draft.effective_date || todayISO();
  formRevisionNotes.value = draft.revision_notes || "";

  if (draft.file_path) {
    currentFileInfo.classList.remove("hidden");
    currentFileInfo.textContent =
      `目前檔案：${draft.file_name || "內規檔案"}。如需替換，重新選擇檔案即可。`;
  } else {
    currentFileInfo.classList.remove("hidden");
    currentFileInfo.textContent = "此草稿尚未上傳檔案，發布前必須選擇檔案。";
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

async function saveDraft() {
  if (!regulationForm.reportValidity()) return null;

  const selectedFile = formFile.files?.[0] || null;

  if (!editorState.existingFilePath && !selectedFile) {
    setEditorMessage("請先選擇要上傳的內規檔案。", true);
    return null;
  }

  if (selectedFile) {
    const fileError = validateFile(selectedFile);
    if (fileError) {
      setEditorMessage(fileError, true);
      return null;
    }
  }

  setEditorMessage("正在儲存…");

  const title = formTitle.value.trim();
  const category = formCategory.value.trim();
  const versionLabel = formVersion.value.trim();
  const effectiveDate = formEffectiveDate.value;
  const revisionNotes = formRevisionNotes.value.trim();

  let regulationId = editorState.regulationId;

  if (editorState.mode === "new" && !regulationId) {
    const { data: newReg, error } = await client
      .from("regulations")
      .insert({
        slug: `rule-${Date.now()}`,
        title,
        category,
        is_active: true
      })
      .select("id")
      .single();

    if (error) {
      console.error(error);
      setEditorMessage(explainSaveError(error), true);
      return null;
    }

    regulationId = newReg.id;
    editorState.regulationId = regulationId;
    editorState.mode = "existing";
    selectedAdminId = regulationId;
  } else {
    const { error } = await client
      .from("regulations")
      .update({
        title,
        category,
        updated_at: new Date().toISOString()
      })
      .eq("id", regulationId);

    if (error) {
      console.error(error);
      setEditorMessage(explainSaveError(error), true);
      return null;
    }
  }

  let uploaded = null;

  if (selectedFile) {
    try {
      uploaded = await uploadFile(regulationId, selectedFile);
    } catch (error) {
      console.error(error);
      setEditorMessage(`檔案上傳失敗：${error.message}`, true);
      return null;
    }
  }

  const payload = {
    regulation_id: regulationId,
    version_label: versionLabel,
    effective_date: effectiveDate,
    revision_notes: revisionNotes,
    status: "draft",
    created_by: currentSession.user.id
  };

  if (uploaded) {
    payload.file_path = uploaded.path;
    payload.file_name = selectedFile.name;
    payload.file_mime_type = selectedFile.type || null;
    payload.file_size = selectedFile.size;
  }

  const oldFilePath = editorState.existingFilePath;

  if (editorState.versionId) {
    const { error } = await client
      .from("regulation_versions")
      .update(payload)
      .eq("id", editorState.versionId);

    if (error) {
      console.error(error);

      if (uploaded?.path) {
        await safeDeleteFile(uploaded.path);
      }

      setEditorMessage(explainSaveError(error), true);
      return null;
    }
  } else {
    const { data: newVersion, error } = await client
      .from("regulation_versions")
      .insert(payload)
      .select("id")
      .single();

    if (error) {
      console.error(error);

      if (uploaded?.path) {
        await safeDeleteFile(uploaded.path);
      }

      setEditorMessage(explainSaveError(error), true);
      return null;
    }

    editorState.versionId = newVersion.id;
  }

  if (uploaded?.path && oldFilePath && oldFilePath !== uploaded.path) {
    await safeDeleteFile(oldFilePath);
  }

  if (uploaded?.path) {
    editorState.existingFilePath = uploaded.path;
    editorState.existingFileName = selectedFile.name;
  }

  formFile.value = "";
  setEditorMessage("草稿已儲存。", false);

  await loadAdminData();
  openExistingDraft(editorState.versionId);
  setEditorMessage("草稿已儲存。", false);

  return editorState.versionId;
}

async function publishCurrentDraft() {
  const versionId = await saveDraft();
  if (!versionId) return;

  const versionLabel = formVersion.value.trim();

  const confirmed = window.confirm(
    `確定要發布版本 ${versionLabel} 嗎？\n\n發布後員工會立即可以下載此檔案；原本正式版本會保留為歷史版本。`
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

/* File */

function validateFile(file) {
  const extension = file.name.split(".").pop()?.toLowerCase() || "";

  if (!ALLOWED_EXTENSIONS.includes(extension)) {
    return "目前僅支援 PDF、DOC、DOCX 檔案。";
  }

  if (file.size > MAX_FILE_SIZE) {
    return "檔案超過 25MB，請縮小後再上傳。";
  }

  return "";
}

async function uploadFile(regulationId, file) {
  const extension = file.name.split(".").pop()?.toLowerCase() || "bin";
  const unique = crypto.randomUUID();
  const path = `${regulationId}/${unique}.${extension}`;

  const { data, error } = await client.storage
    .from(FILE_BUCKET)
    .upload(path, file, {
      cacheControl: "3600",
      upsert: false,
      contentType: file.type || undefined
    });

  if (error) throw error;
  return data;
}

async function downloadRegulationFile(path, fileName) {
  if (!path) return;

  const { data, error } = await client.storage
    .from(FILE_BUCKET)
    .download(path);

  if (error) {
    console.error(error);
    window.alert("檔案下載失敗，請稍後再試。");
    return;
  }

  const objectUrl = URL.createObjectURL(data);
  const anchor = document.createElement("a");
  anchor.href = objectUrl;
  anchor.download = fileName || "內規檔案";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();

  setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
}

async function safeDeleteFile(path) {
  if (!path) return;
  const { error } = await client.storage.from(FILE_BUCKET).remove([path]);
  if (error) console.warn("舊檔案清理失敗：", error);
}

/* Helpers */

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

function formatFileSize(bytes) {
  if (!bytes && bytes !== 0) return "檔案大小未記錄";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
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

  if (msg.includes("duplicate key")) {
    return "這個版本號已經使用過，請改用新的版本號。";
  }

  if (msg.includes("row-level security")) {
    return "你的帳號沒有這項修改權限。";
  }

  return `儲存失敗：${msg}`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

/* Events */

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
