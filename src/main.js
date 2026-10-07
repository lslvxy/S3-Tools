'use strict';

// ─────────────────────────────────────────────────────────────
// Tauri API access (withGlobalTauri)
// ─────────────────────────────────────────────────────────────
const invoke = window.__TAURI__.core.invoke;
const dialog = window.__TAURI__.dialog;
const opener = window.__TAURI__.opener;
const clipboard = window.__TAURI__.clipboardManager;
const listen = window.__TAURI__.event.listen;

const $ = (id) => document.getElementById(id);

// ─────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────
const state = {
  profiles: [],
  selectedProfile: null,
  connectionStatus: 'disconnected', // disconnected | connecting | connected | failed
  isUploadEnabled: false,
  buckets: [],
  selectedBucket: null,
  currentPrefix: '',
  objects: [],
  selectedObjects: new Set(),
  lastSelectedKey: null,
  hasMorePages: false,
  currentPage: 1,
  pageStartTokens: [null],
  isLoading: false,
  filterPattern: '',
  searchQuery: '',
  searchResults: [],
  searchNextToken: null,
  searchTruncated: false,
  searchLoading: false,
  isSearchMode: false,
  searchTimer: null,
  downloadTasks: [],
  uploadTasks: [],
  logEntries: [],
  completionSuggestions: [],
  showCompletions: false,
  settings: null,
  bookmarks: [],
  currentError: null,
  showError: false,
  sortKey: 'date',
  sortDir: 'desc',
  // caches
  objectCache: new Map(), // key -> {objects, token, ts}
  completionCache: new Map(), // key -> {results, expiry}
  // debounce handles
  filterTimer: null,
  completionTimer: null,
  completionReq: 0,
  connectionReq: Date.now(),
  objectReq: 0,
  searchReq: 0,
};

const CACHE_TTL = 5 * 60 * 1000;
const OBJECT_CACHE_LIMIT = 20;
const OBJECT_CACHE_ITEM_LIMIT = 5000;
const COMPLETION_CACHE_LIMIT = 100;

function pruneCaches() {
  const now = Date.now();
  let objectCount = 0;
  for (const [key, entry] of state.objectCache) {
    if (now - entry.ts >= CACHE_TTL) state.objectCache.delete(key);
    else objectCount += entry.objects.length;
  }
  while (state.objectCache.size > OBJECT_CACHE_LIMIT || objectCount > OBJECT_CACHE_ITEM_LIMIT) {
    const key = state.objectCache.keys().next().value;
    objectCount -= state.objectCache.get(key).objects.length;
    state.objectCache.delete(key);
  }
  for (const [key, entry] of state.completionCache) {
    if (entry.expiry <= now) state.completionCache.delete(key);
  }
  while (state.completionCache.size > COMPLETION_CACHE_LIMIT) {
    state.completionCache.delete(state.completionCache.keys().next().value);
  }
}

// Release expired entries even when the user stops navigating.
setInterval(pruneCaches, 60 * 1000);

// ─────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function formatSize(n) {
  if (n == null) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${i === 0 || v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

function formatSpeed(bytesPerSec) {
  if (!bytesPerSec) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = bytesPerSec, i = 0;
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
  return `${i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}/s`;
}

function formatDate(iso) {
  if (!iso) return '-';
  // backend gives "2026-03-31 12:34:56" or "2026-03-31T12:34:56.123"
  const d = new Date(iso.replace(' ', 'T'));
  if (isNaN(d)) return iso;
  return d.toLocaleString('zh-CN', { dateStyle: 'short', timeStyle: 'short' });
}

function directoryPrefix(path) {
  if (path.endsWith('/')) return path;
  const i = path.lastIndexOf('/');
  return i >= 0 ? path.slice(0, i + 1) : '';
}

function fileNameOf(key) {
  return key.split('/').pop() || key;
}

function newUuid() {
  if (window.crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

async function showAppError(err) {
  let title = '错误', message = String(err), suggestion = '';
  if (err && typeof err === 'object') {
    title = err.title || '错误';
    message = err.message || String(err);
    suggestion = err.suggestion || '';
  }
  state.currentError = { title, message, suggestion };
  $('errorTitle').textContent = title;
  $('errorMessage').textContent = message;
  $('errorSuggestion').textContent = suggestion ? `建议：${suggestion}` : '';
  $('errorModal').classList.remove('hidden');
  state.showError = true;
}

function closeError() {
  $('errorModal').classList.add('hidden');
  state.showError = false;
}

async function copyText(text) {
  try {
    await clipboard.writeText(text);
  } catch (e) {
    console.error('copy failed', e);
  }
}

async function revealPath(path) {
  try {
    await opener.revealItemInDir(path);
  } catch (e) {
    console.error('reveal failed', e);
  }
}

async function openPath(path) {
  try {
    await opener.openPath(path);
  } catch (e) {
    console.error('open failed', e);
  }
}

// ─────────────────────────────────────────────────────────────
// Init
// ─────────────────────────────────────────────────────────────
async function init() {
  try {
    const [profiles, settings, logs, settingsWarning] = await Promise.all([
      invoke('get_profiles'),
      invoke('get_settings'),
      invoke('get_logs'),
      invoke('get_settings_load_warning'),
    ]);
    state.profiles = profiles;
    state.settings = settings;
    state.bookmarks = settings.bookmarks || [];
    state.logEntries = logs;
    renderProfileSelect();
    renderLogs();

    const lastName = settings.last_profile_name || '';
    const target = profiles.find((p) => p.name === lastName) || profiles[0];
    if (target) {
      await connectProfile(target.name);
    } else {
      setStatus('disconnected', '未连接');
      renderBucketList();
    }
    if (settingsWarning) showAppError({ title: '配置读取失败', message: settingsWarning, suggestion: '当前使用默认设置；请修复原配置后重新加载。' });
  } catch (e) {
    setStatus('failed', '初始化失败');
    showAppError(e);
  }

  listen('download-update', (event) => {
    onDownloadUpdate(event.payload);
  });
  listen('upload-update', (event) => {
    onUploadUpdate(event.payload);
  });
  listen('log-entry', (event) => {
    state.logEntries.unshift(event.payload);
    if (state.logEntries.length > 1000) state.logEntries.length = 1000;
    appendLogEntry(event.payload);
  });
}

// ─────────────────────────────────────────────────────────────
// Toolbar
// ─────────────────────────────────────────────────────────────
function setStatus(status, text) {
  state.connectionStatus = status;
  $('statusDot').className = `dot ${status}`;
  $('statusText').textContent = text || '';
}

function renderProfileSelect() {
  const sel = $('profileSelect');
  sel.innerHTML = '';
  if (!state.profiles.length) {
    sel.innerHTML = '<option>无可用环境</option>';
    return;
  }
  state.profiles.forEach((p) => {
    const opt = document.createElement('option');
    opt.value = p.name;
    opt.textContent = `${p.is_production ? '☁ ' : '🖥 '}${p.name}`;
    if (state.selectedProfile && p.name === state.selectedProfile.name) opt.selected = true;
    sel.appendChild(opt);
  });
  sel.disabled = !state.profiles.length;
}

$('profileSelect').addEventListener('change', (e) => {
  const name = e.target.value;
  if (name) connectProfile(name);
});

async function connectProfile(name) {
  const request = ++state.connectionReq;
  state.objectReq++;
  state.searchReq++;
  clearTimeout(state.searchTimer);
  clearTimeout(state.filterTimer);
  state.isLoading = false;
  state.selectedProfile = null;
  state.isUploadEnabled = false;
  renderLoading();
  renderUploadControls();
  setStatus('connecting', '连接中...');
  state.selectedBucket = null;
  state.currentPrefix = '';
  state.objects = [];
  state.buckets = [];
  state.currentPage = 1;
  state.pageStartTokens = [null];
  state.filterPattern = '';
  state.isSearchMode = false;
  state.searchQuery = '';
  state.searchResults = [];
  state.searchNextToken = null;
  state.searchTruncated = false;
  state.searchLoading = false;
  $('filterInput').value = '';
  $('searchInput').value = '';
  $('searchClear').classList.add('hidden');
  updatePathInput();
  state.objectCache.clear();
  state.completionCache.clear();
  state.completionReq++;
  clearTimeout(state.completionTimer);
  hideCompletions();
  renderBucketList();
  renderFileArea();

  try {
    const res = await invoke('connect_profile', { name, requestId: request });
    if (request !== state.connectionReq) return;
    state.selectedProfile = res.profile;
    state.buckets = res.buckets;
    state.isUploadEnabled = false;
    renderProfileSelect();
    setStatus('connected', '已连接');
    renderBucketList();
    renderUploadControls();

    if (res.profile.default_bucket && res.buckets.includes(res.profile.default_bucket)) {
      state.selectedBucket = res.profile.default_bucket;
      await loadObjects(res.profile.default_bucket, '', { reset: true });
    }
  } catch (e) {
    if (request !== state.connectionReq) return;
    setStatus('failed', `连接失败: ${e.message || e}`);
    showAppError(e);
  }
}

$('refreshBtn').addEventListener('click', () => {
  if (state.selectedBucket) {
    loadObjects(state.selectedBucket, state.currentPrefix, { reset: true, forceRefresh: true });
  } else {
    reloadBuckets();
  }
});

$('uploadToggle').addEventListener('click', () => {
  state.isUploadEnabled = !state.isUploadEnabled;
  renderUploadControls();
});

function renderUploadControls() {
  const isProd = state.selectedProfile ? state.selectedProfile.is_production : true;
  const toggle = $('uploadToggle');
  const uploadBtn = $('uploadBtn');
  if (isProd) {
    toggle.classList.add('hidden');
    uploadBtn.classList.add('hidden');
    return;
  }
  toggle.classList.remove('hidden');
  toggle.classList.toggle('on', state.isUploadEnabled);
  toggle.textContent = state.isUploadEnabled ? '⬆ 上传已开' : '⬆ 允许上传';
  uploadBtn.classList.toggle('hidden', !state.isUploadEnabled);
}

// ─────────────────────────────────────────────────────────────
// Sidebar / Buckets
// ─────────────────────────────────────────────────────────────
async function reloadBuckets() {
  try {
    const buckets = await invoke('list_buckets');
    state.buckets = buckets;
    renderBucketList();
  } catch (e) {
    showAppError(e);
  }
}

function renderBucketList() {
  const wrap = $('bucketSearchWrap');
  const list = $('bucketList');
  wrap.classList.toggle('hidden', state.buckets.length === 0);

  const q = ($('bucketSearch').value || '').toLowerCase();
  const filtered = state.buckets.filter((b) => b.toLowerCase().includes(q));
  list.innerHTML = '';

  if (!state.buckets.length && (state.connectionStatus === 'disconnected' || state.connectionStatus === 'failed')) {
    list.innerHTML = '<div class="empty-hint">未连接<br/>请选择环境并连接</div>';
  } else if (!state.buckets.length && state.connectionStatus === 'connected') {
    list.innerHTML = '<div class="empty-hint">无 Bucket</div>';
  } else if (!filtered.length) {
    list.innerHTML = `<div class="empty-hint">没有名称包含 "${q}" 的 bucket</div>`;
  } else {
    filtered.forEach((b) => {
      const div = document.createElement('div');
      div.className = 'bucket-item' + (b === state.selectedBucket ? ' active' : '');
      div.dataset.bucket = b;
      div.innerHTML = `<span>🛢</span><span class="bname">${escapeHtml(b)}</span>${b === state.selectedBucket ? '<span class="star">★</span>' : ''}`;
      div.addEventListener('click', () => selectBucket(b));
      div.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        e.stopPropagation();
        showContextMenu(e.clientX, e.clientY, [
          { label: '复制名称', action: () => copyText(b) },
        ]);
      });
      list.appendChild(div);
    });
  }
}

$('bucketSearch').addEventListener('input', () => {
  renderBucketList();
  $('bucketSearchClear').classList.toggle('hidden', !$('bucketSearch').value);
});
$('bucketSearchClear').addEventListener('click', () => {
  $('bucketSearch').value = '';
  $('bucketSearchClear').classList.add('hidden');
  renderBucketList();
});

async function selectBucket(bucket) {
  state.selectedBucket = bucket;
  state.currentPrefix = '';
  state.filterPattern = '';
  $('filterInput').value = '';
  renderBucketList();
  await loadObjects(bucket, '', { reset: true });
}

// ─────────────────────────────────────────────────────────────
// Object listing (cache + pagination)
// ─────────────────────────────────────────────────────────────
function cacheKey(bucket, prefix) {
  return `${bucket}\u0000${prefix}`;
}

async function loadObjects(bucket, prefix, { reset = true, forceRefresh = false } = {}) {
  pruneCaches();
  if (!reset) {
    await loadPage(bucket, prefix, state.currentPage + 1);
    return;
  }

  const request = ++state.objectReq;
  state.searchReq++;
  state.completionReq++;
  clearTimeout(state.completionTimer);
  hideCompletions();
  // reset → page 1
  state.pageStartTokens = [null];
  state.currentPage = 1;

  if (!forceRefresh) {
    const key = cacheKey(bucket, prefix);
    const cached = state.objectCache.get(key);
    if (cached && Date.now() - cached.ts < CACHE_TTL) {
      state.objectCache.delete(key);
      state.objectCache.set(key, cached);
      state.isLoading = false;
      renderLoading();
      state.objects = cached.objects;
      state.pageStartTokens = [null, cached.token];
      state.hasMorePages = !!cached.token;
      state.currentPage = 1;
      renderFileArea();
      return;
    }
  }

  const loaded = await loadPage(bucket, prefix, 1, request);
  if (!loaded || request !== state.objectReq) return;
  state.objectCache.delete(cacheKey(bucket, prefix));
  state.objectCache.set(cacheKey(bucket, prefix), {
    objects: state.objects,
    token: state.pageStartTokens[1] ?? null,
    ts: Date.now(),
  });
  pruneCaches();
}

async function loadPage(bucket, prefix, page, request = ++state.objectReq) {
  if (page < 1) return;
  const token = state.pageStartTokens[page - 1] ?? null;
  state.isLoading = true;
  renderLoading();

  try {
    const result = await invoke('list_objects', {
      args: {
        bucket,
        prefix,
        continuation_token: token,
        page_size: state.settings.page_size,
      },
    });
    if (request !== state.objectReq) return false;
    state.objects = result.objects;
    state.pageStartTokens[page] = result.nextToken ?? null;
    state.currentPage = page;
    state.hasMorePages = !!result.nextToken;
    return true;
  } catch (e) {
    if (request === state.objectReq) showAppError(e);
    return false;
  } finally {
    if (request === state.objectReq) {
      state.isLoading = false;
      renderLoading();
      renderFileArea();
    }
  }
}

function renderLoading() {
  const overlay = $('loadingOverlay');
  overlay.classList.toggle('hidden', !state.isLoading);
  $('pageLoading').classList.toggle('hidden', !state.isLoading);
  $('refreshBtn').disabled = state.isLoading;
}

// ─────────────────────────────────────────────────────────────
// Path input + completion
// ─────────────────────────────────────────────────────────────
function updatePathInput() {
  $('pathInput').value = state.currentPrefix + state.filterPattern;
  const label = $('pathBucketLabel');
  if (state.selectedBucket) {
    label.textContent = state.selectedBucket;
    label.classList.remove('hidden');
  } else {
    label.classList.add('hidden');
  }
}

function requestCompletions(input) {
  clearTimeout(state.completionTimer);
  const request = ++state.completionReq;
  if (!input) {
    hideCompletions();
    return;
  }
  state.completionTimer = setTimeout(async () => {
    if (!state.selectedBucket) return;
    pruneCaches();
    const cacheKey = `${state.selectedBucket}/${input}`;
    const cached = state.completionCache.get(cacheKey);
    if (cached && cached.expiry > Date.now()) {
      state.completionCache.delete(cacheKey);
      state.completionCache.set(cacheKey, cached);
      showCompletions(cached.results);
      return;
    }
    try {
      const results = await invoke('list_completion', {
        args: { bucket: state.selectedBucket, prefix: input },
      });
      if (request !== state.completionReq) return;
      const dirs = results.filter((r) => r.endsWith('/'));
      state.completionCache.set(cacheKey, {
        results: dirs,
        expiry: Date.now() + (state.settings.completion_cache_ttl || 60) * 1000,
      });
      pruneCaches();
      showCompletions(dirs);
    } catch (e) {
      if (request !== state.completionReq) return;
      hideCompletions();
    }
  }, 300);
}

function showCompletions(suggestions) {
  const list = $('completionList');
  list.innerHTML = '';
  state.completionSuggestions = suggestions;
  if (!suggestions.length) { hideCompletions(); return; }
  suggestions.slice(0, 10).forEach((s) => {
    const item = document.createElement('div');
    item.className = 'completion-item';
    item.innerHTML = `${s.endsWith('/') ? '📁' : '📄'} ${escapeHtml(s)}`;
    item.addEventListener('click', () => {
      $('pathInput').value = s;
      hideCompletions();
    });
    list.appendChild(item);
  });
  list.classList.remove('hidden');
}

function hideCompletions() {
  state.completionSuggestions = [];
  $('completionList').classList.add('hidden');
}

$('pathInput').addEventListener('input', (e) => {
  requestCompletions(e.target.value);
});
$('pathInput').addEventListener('keydown', (e) => {
  if (e.key === 'Escape') hideCompletions();
  if (e.key === 'Enter') { e.preventDefault(); navigateToPath(); }
});
$('pathInput').addEventListener('focus', () => {
  if (state.completionSuggestions.length) $('completionList').classList.remove('hidden');
});
$('pathInput').addEventListener('blur', () => {
  setTimeout(hideCompletions, 200);
});

$('goBtn').addEventListener('click', navigateToPath);

function navigateToPath() {
  if (!state.selectedBucket) return;
  clearFilterSilently();
  const p = $('pathInput').value;
  state.currentPrefix = p;
  hideCompletions();
  loadObjects(state.selectedBucket, p, { reset: true });
}

// ─────────────────────────────────────────────────────────────
// Filter (prefix filtering, 400ms debounce)
// ─────────────────────────────────────────────────────────────
function clearFilterSilently() {
  clearTimeout(state.filterTimer);
  state.filterTimer = null;
  state.filterPattern = '';
  $('filterInput').value = '';
  $('filterClear').classList.add('hidden');
}

$('filterInput').addEventListener('input', (e) => {
  const v = e.target.value;
  state.filterPattern = v;
  $('filterClear').classList.toggle('hidden', !v);
  clearTimeout(state.filterTimer);
  state.filterTimer = setTimeout(() => {
    if (!state.selectedBucket) return;
    const prefix = state.currentPrefix + state.filterPattern;
    loadObjects(state.selectedBucket, prefix, { reset: true });
  }, 400);
});

$('filterClear').addEventListener('click', () => {
  clearFilterSilently();
  if (state.selectedBucket) {
    loadObjects(state.selectedBucket, state.currentPrefix, { reset: true });
  }
});

// ─────────────────────────────────────────────────────────────
// Search (recursive, server-side filename substring)
// ─────────────────────────────────────────────────────────────
function exitSearch() {
  state.searchReq++;
  clearTimeout(state.searchTimer);
  state.searchTimer = null;
  state.isSearchMode = false;
  state.searchQuery = '';
  state.searchResults = [];
  state.searchNextToken = null;
  state.searchTruncated = false;
  state.searchLoading = false;
  $('searchInput').value = '';
  $('searchClear').classList.add('hidden');
  renderFileArea();
}

async function fetchSearchResults(bucket, prefix, query, request, connection, append = false) {
  const current = () => request === state.searchReq && connection === state.connectionReq
    && bucket === state.selectedBucket && prefix === state.currentPrefix;
  if (!current()) return;
  state.searchLoading = true;
  if (state.isSearchMode) renderSearchResults();
  try {
    const result = await invoke('search_objects', {
      args: { bucket, prefix, query, continuation_token: append ? state.searchNextToken : null },
    });
    if (!current()) return;
    state.searchResults = append ? state.searchResults.concat(result.objects) : result.objects;
    state.searchNextToken = result.nextToken;
    state.searchTruncated = result.truncated;
    state.isSearchMode = true;
  } catch (err) {
    if (current()) showAppError(err);
  } finally {
    if (current()) {
      state.searchLoading = false;
      renderFileArea();
    }
  }
}

$('searchInput').addEventListener('input', (e) => {
  const v = e.target.value;
  const request = ++state.searchReq;
  const connection = state.connectionReq;
  const bucket = state.selectedBucket;
  const prefix = state.currentPrefix;
  state.searchQuery = v;
  state.searchNextToken = null;
  state.searchTruncated = false;
  state.searchLoading = true;
  $('searchContinueBtn').disabled = true;
  $('searchClear').classList.toggle('hidden', !v);
  clearTimeout(state.searchTimer);
  if (!v) {
    exitSearch();
    return;
  }
  state.searchTimer = setTimeout(() => {
    if (!bucket || request !== state.searchReq || connection !== state.connectionReq) return;
    fetchSearchResults(bucket, prefix, v, request, connection);
  }, 400);
});

$('searchContinueBtn').addEventListener('click', () => {
  if (!state.searchNextToken || state.searchLoading) return;
  fetchSearchResults(state.selectedBucket, state.currentPrefix, state.searchQuery,
    ++state.searchReq, state.connectionReq, true);
});

$('searchClear').addEventListener('click', exitSearch);

function renderSearchResults() {
  const table = $('fileTable');
  const body = $('fileBody');
  const empty = $('emptyView');
  $('regexDownloadBtn').disabled = true;
  $('paginationBar').classList.add('hidden');
  $('searchStatus').classList.remove('hidden');
  $('searchStatusText').textContent = state.searchLoading ? '搜索中…'
    : state.searchTruncated
      ? `已找到 ${state.searchResults.length} 个结果，尚未搜索完全部对象；可继续搜索或缩小路径范围。`
      : `搜索完成，共 ${state.searchResults.length} 个结果。`;
  $('searchContinueBtn').classList.toggle('hidden', !state.searchNextToken);
  $('searchContinueBtn').disabled = state.searchLoading;

  if (!state.searchResults.length) {
    table.classList.add('hidden');
    empty.classList.remove('hidden');
    empty.innerHTML = `<div style="font-size:30px">🔍</div><div>无匹配结果</div><div class="caption">${state.searchTruncated ? '已扫描范围内没有匹配结果，可继续搜索' : '当前路径下没有文件名包含该关键词的对象'}</div>`;
    return;
  }

  table.classList.remove('hidden');
  empty.classList.add('hidden');
  body.innerHTML = '';

  state.searchResults.forEach((obj) => {
    const tr = document.createElement('tr');
    tr.dataset.key = obj.key;
    const parentPrefix = directoryPrefix(obj.key);
    tr.innerHTML = `
      <td class="col-icon"><span>📄</span></td>
      <td class="col-name"><span class="name-text" title="${escapeHtml(obj.key)}">${escapeHtml(obj.display_name)}</span></td>
      <td class="col-size">${formatSize(obj.size)}</td>
      <td class="col-date">${formatDate(obj.last_modified)}</td>
      <td class="col-action">
        <button class="row-btn" data-action="locate" title="定位到所在目录">📂</button>
        <button class="row-btn" data-action="download" title="下载">⬇</button>
      </td>`;
    tr.addEventListener('dblclick', () => enqueueDownloads([obj]));
    tr.querySelector('[data-action="download"]')?.addEventListener('click', (e) => {
      e.stopPropagation();
      enqueueDownloads([obj]);
    });
    tr.querySelector('[data-action="locate"]')?.addEventListener('click', (e) => {
      e.stopPropagation();
      exitSearch();
      navigateToPathByKey(parentPrefix);
    });
    body.appendChild(tr);
  });
}

// ─────────────────────────────────────────────────────────────
// Breadcrumb
// ─────────────────────────────────────────────────────────────
function renderBreadcrumb() {
  const bar = $('breadcrumb');
  if (!state.currentPrefix) { bar.classList.add('hidden'); bar.innerHTML = ''; return; }
  bar.classList.remove('hidden');
  const parts = state.currentPrefix.split('/').filter((p) => p.length);
  let html = `<a data-bucket="${escapeHtml(state.selectedBucket)}">${escapeHtml(state.selectedBucket)}</a>`;
  parts.forEach((part, idx) => {
    const prefix = parts.slice(0, idx + 1).join('/') + '/';
    html += `<span>/</span><a data-prefix="${escapeHtml(prefix)}">${escapeHtml(part)}</a>`;
  });
  bar.innerHTML = html;
  bar.querySelectorAll('a').forEach((a) => {
    a.addEventListener('click', () => {
      const prefix = a.dataset.prefix || '';
      clearFilterSilently();
      state.currentPrefix = prefix;
      updatePathInput();
      loadObjects(state.selectedBucket, prefix, { reset: true });
    });
  });
}

// ─────────────────────────────────────────────────────────────
// File table
// ─────────────────────────────────────────────────────────────
function sortObjects() {
  const { sortKey, sortDir } = state;
  const dir = sortDir === 'asc' ? 1 : -1;
  return [...state.objects].sort((a, b) => {
    if (a.is_directory !== b.is_directory) return a.is_directory ? -1 : 1;
    let r;
    if (sortKey === 'name') r = a.sortable_name < b.sortable_name ? -1 : (a.sortable_name > b.sortable_name ? 1 : 0);
    else if (sortKey === 'size') r = a.sortable_size - b.sortable_size;
    else r = a.sortable_date - b.sortable_date;
    return r * dir;
  });
}

function renderFileArea() {
  const table = $('fileTable');
  const body = $('fileBody');
  const empty = $('emptyView');
  renderBreadcrumb();

  if (state.isSearchMode) { renderSearchResults(); return; }
  $('searchStatus').classList.add('hidden');

  // empty states
  if (!state.selectedBucket) {
    table.classList.add('hidden');
    empty.classList.remove('hidden');
    empty.innerHTML = '<div style="font-size:30px">🛢</div><div>选择一个 Bucket</div><div class="caption">从左侧选择一个 Bucket 开始浏览</div>';
    renderPagination();
    $('regexDownloadBtn').disabled = true;
    return;
  }
  if (state.isLoading && !state.objects.length) {
    table.classList.add('hidden');
    empty.classList.remove('hidden');
    empty.innerHTML = '<div class="small-spinner"></div><div>加载中...</div>';
    renderPagination();
    return;
  }
  if (!state.objects.length) {
    table.classList.add('hidden');
    empty.classList.remove('hidden');
    const filtering = !!state.filterPattern;
    empty.innerHTML = filtering
      ? '<div style="font-size:30px">🔍</div><div>无匹配文件</div><div class="caption">没有匹配前缀的文件</div>'
      : '<div style="font-size:30px">📁</div><div>此目录为空</div><div class="caption">当前路径没有文件</div>';
    renderPagination();
    return;
  }

  table.classList.remove('hidden');
  empty.classList.add('hidden');
  $('regexDownloadBtn').disabled = false;
  renderSortHeaders();

  body.innerHTML = '';
  const sorted = sortObjects();
  sorted.forEach((obj, idx) => {
    const tr = document.createElement('tr');
    tr.dataset.key = obj.key;
    tr.classList.toggle('selected', state.selectedObjects.has(obj.key));

    const icon = obj.is_directory ? '📁' : '📄';
    const iconColor = obj.is_directory ? 'style="filter:hue-rotate(50deg)"' : '';
    const action = obj.is_directory
      ? `<button class="row-btn" data-action="enter" title="进入目录">➡</button>`
      : `<button class="row-btn" data-action="download" title="下载">⬇</button>`;

    tr.innerHTML = `
      <td class="col-icon"><span ${iconColor}>${icon}</span></td>
      <td class="col-name"><span class="name-text" title="${escapeHtml(obj.key)}">${escapeHtml(obj.display_name)}</span></td>
      <td class="col-size">${formatSize(obj.size)}</td>
      <td class="col-date">${formatDate(obj.last_modified)}</td>
      <td class="col-action">${action}</td>`;

    tr.addEventListener('click', (e) => {
      if (obj.is_directory) return;
      handleSelect(obj.key, idx, sorted, e.metaKey || e.ctrlKey, e.shiftKey);
    });
    tr.addEventListener('dblclick', () => {
      if (obj.is_directory) navigateInto(obj.key);
      else enqueueDownloads([obj]);
    });
    tr.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      if (!state.selectedObjects.has(obj.key)) {
        state.selectedObjects = new Set([obj.key]);
        state.lastSelectedKey = obj.key;
        renderSelection();
        renderDownloadButton();
      }
      const items = [
        { label: `下载选中 (${state.selectedObjects.size} 个)`, action: () => downloadSelected() },
        { label: '—', sep: true },
        { label: '复制名称', action: () => copySelectedNames() },
        { label: '复制路径', action: () => copySelectedPaths() },
      ];
      showContextMenu(e.clientX, e.clientY, items);
    });

    tr.querySelector('[data-action="download"]')?.addEventListener('click', (e) => {
      e.stopPropagation();
      enqueueDownloads([obj]);
    });
    tr.querySelector('[data-action="enter"]')?.addEventListener('click', (e) => {
      e.stopPropagation();
      navigateInto(obj.key);
    });

    body.appendChild(tr);
  });

  renderPagination();
}

function renderSelection() {
  document.querySelectorAll('#fileBody tr').forEach((tr) => {
    tr.classList.toggle('selected', state.selectedObjects.has(tr.dataset.key));
  });
  renderDetails();
}

function renderDetails() {
  const panel = $('detailPanel');
  const body = $('detailBody');
  const keys = [...state.selectedObjects];
  if (keys.length !== 1) {
    panel.classList.add('hidden');
    return;
  }
  const key = keys[0];
  const obj = state.objects.find((o) => o.key === key)
    || state.searchResults.find((o) => o.key === key);
  if (!obj || obj.is_directory) {
    panel.classList.add('hidden');
    return;
  }
  panel.classList.remove('hidden');
  body.innerHTML = `
    <div class="detail-row"><b>名称</b><span>${escapeHtml(obj.display_name)}</span></div>
    <div class="detail-row"><b>路径</b><span>${escapeHtml(obj.key)}</span></div>
    <div class="detail-row"><b>大小</b><span>${formatSize(obj.size)}</span></div>
    <div class="detail-row"><b>修改时间</b><span>${escapeHtml(obj.last_modified || '-')}</span></div>
    <div class="detail-row"><b>ETag</b><span>${escapeHtml(obj.e_tag || '-')}</span></div>
    <div class="detail-row"><b>存储类型</b><span>${escapeHtml(obj.storage_class || '-')}</span></div>
    <div class="detail-row"><b>Content-Type</b><span id="detailContentType">…</span></div>`;
  invoke('head_object', { args: { bucket: state.selectedBucket, key } })
    .then((d) => {
      if (state.selectedObjects.size === 1 && state.selectedObjects.has(key)) {
        const el = $('detailContentType');
        if (el) el.textContent = d.content_type || '-';
      }
    })
    .catch(() => {});
}

function handleSelect(key, idx, sorted, additive, range) {
  if (range && state.lastSelectedKey != null) {
    const anchor = sorted.findIndex((o) => o.key === state.lastSelectedKey);
    const lo = Math.min(anchor, idx);
    const hi = Math.max(anchor, idx);
    const picked = new Set(sorted.slice(lo, hi + 1).filter((o) => !o.is_directory).map((o) => o.key));
    if (additive) {
      picked.forEach((k) => state.selectedObjects.add(k));
    } else {
      state.selectedObjects = picked;
    }
    state.lastSelectedKey = key;
  } else if (additive) {
    if (state.selectedObjects.has(key)) state.selectedObjects.delete(key);
    else state.selectedObjects.add(key);
    state.lastSelectedKey = key;
  } else {
    state.selectedObjects = new Set([key]);
    state.lastSelectedKey = key;
  }
  renderSelection();
  renderDownloadButton();
}

function renderDownloadButton() {
  const btn = $('downloadSelectedBtn');
  const count = state.selectedObjects.size;
  btn.disabled = count === 0;
  $('downloadSelectedCount').textContent = count > 0 ? ` ${count}` : '';
}

function renderSortHeaders() {
  document.querySelectorAll('#fileTable th.sortable').forEach((th) => {
    const key = th.dataset.sort;
    const arrow = state.sortKey === key ? (state.sortDir === 'asc' ? ' ▲' : ' ▼') : '';
    th.querySelector('.arrow')?.remove();
    if (arrow) {
      const span = document.createElement('span');
      span.className = 'arrow';
      span.textContent = arrow;
      th.appendChild(span);
    }
  });
}

document.querySelectorAll('#fileTable th.sortable').forEach((th) => {
  th.addEventListener('click', () => {
    const key = th.dataset.sort;
    if (state.sortKey === key) {
      state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
    } else {
      state.sortKey = key;
      state.sortDir = 'desc';
    }
    renderFileArea();
    renderSortHeaders();
  });
});

function navigateInto(key) {
  if (!state.selectedBucket) return;
  clearFilterSilently();
  state.currentPrefix = key;
  updatePathInput();
  loadObjects(state.selectedBucket, key, { reset: true });
}

function navigateToPathByKey(path) {
  if (!state.selectedBucket) return;
  clearFilterSilently();
  state.currentPrefix = path;
  updatePathInput();
  loadObjects(state.selectedBucket, path, { reset: true });
}

// ─────────────────────────────────────────────────────────────
// Pagination
// ─────────────────────────────────────────────────────────────
function renderPagination() {
  const bar = $('paginationBar');
  if (!state.selectedBucket || !state.objects.length) { bar.classList.add('hidden'); return; }
  bar.classList.remove('hidden');
  const filtering = !!state.filterPattern;
  $('pageInfo').textContent = filtering
    ? `前缀过滤: ${state.objects.length} 个对象`
    : `${state.objects.length} 个对象`;
  $('pageNum').textContent = `第 ${state.currentPage} 页`;
  $('prevPageBtn').disabled = state.currentPage <= 1 || state.isLoading;
  $('nextPageBtn').disabled = !state.hasMorePages || state.isLoading;
}

$('selectAllBtn').addEventListener('click', () => {
  state.selectedObjects = new Set(
    state.objects.filter((o) => !o.is_directory).map((o) => o.key)
  );
  renderSelection();
  renderDownloadButton();
});
$('clearSelBtn').addEventListener('click', () => {
  state.selectedObjects = new Set();
  state.lastSelectedKey = null;
  renderSelection();
  renderDownloadButton();
});
$('prevPageBtn').addEventListener('click', () => {
  if (!state.selectedBucket || state.currentPage <= 1 || state.isLoading) return;
  loadPage(state.selectedBucket, state.currentPrefix, state.currentPage - 1);
});
$('nextPageBtn').addEventListener('click', () => {
  if (!state.selectedBucket || !state.hasMorePages || state.isLoading) return;
  loadPage(state.selectedBucket, state.currentPrefix, state.currentPage + 1);
});

// ─────────────────────────────────────────────────────────────
// Downloads
// ─────────────────────────────────────────────────────────────
async function downloadSelected() {
  const objects = state.objects.filter((o) => state.selectedObjects.has(o.key) && !o.is_directory);
  if (!objects.length) return;
  await enqueueDownloads(objects);
}

async function enqueueDownloads(objects) {
  if (!state.selectedBucket) return;
  const items = objects.map((o) => ({ key: o.key, size: o.size || 0 }));
  try {
    await invoke('download_selected', { bucket: state.selectedBucket, items });
  } catch (e) {
    showAppError(e);
  }
}

$('downloadSelectedBtn').addEventListener('click', downloadSelected);

function onDownloadUpdate(task) {
  const idx = state.downloadTasks.findIndex((t) => t.id === task.id);
  if (idx >= 0) state.downloadTasks[idx] = task;
  else state.downloadTasks.push(task);
  renderDownloadPanel();
}

function renderDownloadPanel() {
  const panel = $('downloadPanel');
  const active = state.downloadTasks.filter((t) => !['completed', 'cancelled', 'skipped'].includes(t.status));
  if (!active.length && !state.downloadTasks.length) {
    panel.classList.add('hidden');
    return;
  }
  panel.classList.remove('hidden');

  const inProgress = state.downloadTasks.filter((t) => t.status === 'in_progress').length;
  const failed = state.downloadTasks.filter((t) => t.status === 'failed').length;
  const completed = state.downloadTasks.filter((t) => t.status === 'completed').length;
  const parts = [];
  if (inProgress) parts.push(`${inProgress} 个下载中`);
  if (failed) parts.push(`${failed} 个失败`);
  if (completed) parts.push(`${completed} 个完成`);
  $('downloadSummary').textContent = parts.join(' · ');

  const list = $('downloadList');
  list.innerHTML = '';
  state.downloadTasks.forEach((t) => {
    const row = document.createElement('div');
    row.className = 'download-row';
    const statusText = {
      pending: '等待中', in_progress: `${Math.round(t.progress * 100)}%`,
      completed: '完成', failed: `失败: ${t.error || ''}`, cancelled: '已取消',
      skipped: '已跳过',
    }[t.status];

    let cancelBtn = '';
    if (t.status === 'pending' || t.status === 'in_progress') {
      cancelBtn = `<button class="row-btn" data-cancel="${t.id}" title="取消下载">✕</button>`;
    }
    let revealBtn = '';
    if (t.status === 'completed' && t.local_url) {
      revealBtn = `<button class="row-btn" data-reveal="${escapeHtml(t.local_url)}" title="在 Finder 中显示">📁</button>`;
    }

    row.innerHTML = `
      <span class="status-icon">${t.status === 'in_progress' ? '<span class="small-spinner"></span>' : ''}</span>
      <span class="dl-name" title="${escapeHtml(t.key)}">${escapeHtml(t.file_name)}</span>
      <div class="progress-wrap">
        <div class="progress-bar"><div style="width:${Math.round(t.progress * 100)}%"></div></div>
      </div>
      <div class="dl-meta">
        <span class="status-${t.status}">${escapeHtml(statusText)}</span>
        <span>${formatSpeed(t.speed)}${t.size ? ' · ' + formatSize(t.size) : ''}</span>
      </div>
      ${cancelBtn}${revealBtn}`;

    row.querySelector('[data-cancel]')?.addEventListener('click', () => {
      invoke('cancel_download', { id: t.id }).catch(console.error);
    });
    row.querySelector('[data-reveal]')?.addEventListener('click', () => {
      revealPath(t.local_url);
    });
    list.appendChild(row);
  });
}

$('clearCompletedBtn').addEventListener('click', () => {
  state.downloadTasks = state.downloadTasks.filter(
    (t) => !['completed', 'cancelled', 'skipped'].includes(t.status)
  );
  renderDownloadPanel();
});

$('downloadToggleBtn').addEventListener('click', () => {
  $('downloadPanel').classList.toggle('collapsed');
  $('downloadToggleBtn').textContent = $('downloadPanel').classList.contains('collapsed') ? '▴' : '▾';
});

// ─────────────────────────────────────────────────────────────
// Regex download
// ─────────────────────────────────────────────────────────────
function regexMatchCount() {
  const pattern = $('regexInput').value;
  if (!pattern) return 0;
  try {
    const re = new RegExp(pattern, 'i');
    return state.objects.filter((o) => !o.is_directory && re.test(o.display_name)).length;
  } catch {
    return -1;
  }
}

$('regexDownloadBtn').addEventListener('click', () => {
  $('regexInput').value = '';
  $('regexCount').textContent = '';
  $('regexStart').disabled = true;
  $('regexModal').classList.remove('hidden');
  $('regexInput').focus();
});

$('regexInput').addEventListener('input', () => {
  const n = regexMatchCount();
  if (n < 0) $('regexCount').textContent = '正则表达式无效';
  else $('regexCount').textContent = n > 0 ? `匹配到 ${n} 个文件` : '匹配到 0 个文件';
  $('regexStart').disabled = n <= 0;
});

$('regexCancel').addEventListener('click', () => $('regexModal').classList.add('hidden'));
$('regexStart').addEventListener('click', async () => {
  const pattern = $('regexInput').value;
  const re = new RegExp(pattern, 'i');
  const matched = state.objects.filter((o) => !o.is_directory && re.test(o.display_name));
  await enqueueDownloads(matched);
  $('regexModal').classList.add('hidden');
});

// ─────────────────────────────────────────────────────────────
// Upload
// ─────────────────────────────────────────────────────────────
function uploadPaths(paths) {
  if (!paths.length || !state.selectedBucket) return;
  const files = paths.map((file) => ({
    key: state.currentPrefix + (file.split(/[\\/]/).pop() || file),
    file_path: file,
  }));
  invoke('upload_files', { args: { bucket: state.selectedBucket, files } })
    .then(() => {
      loadObjects(state.selectedBucket, state.currentPrefix, { reset: true, forceRefresh: true });
    })
    .catch(showAppError);
}

$('uploadBtn').addEventListener('click', async () => {
  const selected = await dialog.open({ multiple: true, directory: false });
  const files = selected ? (Array.isArray(selected) ? selected : [selected]) : [];
  uploadPaths(files);
});

function onUploadUpdate(task) {
  const idx = state.uploadTasks.findIndex((t) => t.id === task.id);
  if (idx >= 0) state.uploadTasks[idx] = task;
  else state.uploadTasks.push(task);
  renderUploadPanel();
}

function renderUploadPanel() {
  const panel = $('uploadPanel');
  const active = state.uploadTasks.filter((t) => !['completed', 'cancelled', 'failed'].includes(t.status));
  if (!state.uploadTasks.length) {
    panel.classList.add('hidden');
    return;
  }
  panel.classList.remove('hidden');

  const inProgress = state.uploadTasks.filter((t) => t.status === 'in_progress').length;
  const failed = state.uploadTasks.filter((t) => t.status === 'failed').length;
  const completed = state.uploadTasks.filter((t) => t.status === 'completed').length;
  const parts = [];
  if (inProgress) parts.push(`${inProgress} 个上传中`);
  if (failed) parts.push(`${failed} 个失败`);
  if (completed) parts.push(`${completed} 个完成`);
  $('uploadSummary').textContent = parts.join(' · ');

  const list = $('uploadList');
  list.innerHTML = '';
  state.uploadTasks.forEach((t) => {
    const row = document.createElement('div');
    row.className = 'download-row';
    const statusText = {
      pending: '等待中', in_progress: `${Math.round(t.progress * 100)}%`,
      completed: '完成', failed: `失败: ${t.error || ''}`, cancelled: '已取消',
    }[t.status];
    const cancelBtn = (t.status === 'pending' || t.status === 'in_progress')
      ? `<button class="row-btn" data-cancel="${t.id}" title="取消上传">✕</button>` : '';
    row.innerHTML = `
      <span class="status-icon">${t.status === 'in_progress' ? '<span class="small-spinner"></span>' : ''}</span>
      <span class="dl-name" title="${escapeHtml(t.key)}">${escapeHtml(t.file_name)}</span>
      <div class="progress-wrap">
        <div class="progress-bar"><div style="width:${Math.round(t.progress * 100)}%"></div></div>
      </div>
      <div class="dl-meta"><span class="status-${t.status}">${escapeHtml(statusText)}</span>
        <span>${t.size ? formatSize(t.size) : ''}</span></div>
      ${cancelBtn}`;
    row.querySelector('[data-cancel]')?.addEventListener('click', () => {
      invoke('cancel_upload', { id: t.id }).catch(console.error);
    });
    list.appendChild(row);
  });
}

$('uploadToggleBtn').addEventListener('click', () => {
  $('uploadPanel').classList.toggle('collapsed');
  $('uploadToggleBtn').textContent = $('uploadPanel').classList.contains('collapsed') ? '▴' : '▾';
});

// Drag-drop upload
let dragDepth = 0;
document.addEventListener('dragover', (e) => { e.preventDefault(); });
document.addEventListener('drop', (e) => { e.preventDefault(); });
listen('tauri://drag-enter', () => {
  dragDepth += 1;
  $('dropOverlay').classList.toggle('hidden', false);
});
listen('tauri://drag-leave', () => {
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) $('dropOverlay').classList.add('hidden');
});
listen('tauri://drag-drop', (event) => {
  dragDepth = 0;
  $('dropOverlay').classList.add('hidden');
  const paths = event.payload?.paths || [];
  if (!paths.length || !state.selectedBucket || !state.isUploadEnabled) return;
  uploadPaths(paths);
});

// ─────────────────────────────────────────────────────────────
// Bookmarks
// ─────────────────────────────────────────────────────────────
function persistBookmarks() {
  state.settings.bookmarks = state.bookmarks;
  persistSettings();
}

function renderBookmarkMenu() {
  const menu = $('bookmarkMenu');
  menu.innerHTML = '';
  if (menu.classList.contains('hidden')) return;

  const currentDir = state.currentPrefix;
  const addItem = document.createElement('div');
  addItem.className = 'bookmark-item';
  const canAdd = currentDir && state.selectedBucket;
  addItem.innerHTML = `<span class="bm-name">${canAdd ? `+ 添加书签: ${escapeHtml(currentDir)}` : '+ 添加书签（请先进入目录）'}</span>`;
  addItem.style.opacity = canAdd ? 1 : 0.5;
  addItem.addEventListener('click', () => {
    if (!canAdd) return;
    $('newBookmarkName').value = currentDir.split('/').filter(Boolean).pop() || currentDir;
    $('newBookmarkPath').value = currentDir;
    $('addBookmarkSave').disabled = !currentDir;
    $('addBookmarkModal').classList.remove('hidden');
    menu.classList.add('hidden');
  });
  menu.appendChild(addItem);

  const manageItem = document.createElement('div');
  manageItem.className = 'bookmark-item';
  manageItem.innerHTML = `<span class="bm-name">📋 管理书签...</span>`;
  manageItem.addEventListener('click', () => {
    menu.classList.add('hidden');
    openBookmarkManager();
  });
  menu.appendChild(manageItem);

  if (state.bookmarks.length) {
    const sep = document.createElement('div');
    sep.className = 'menu-section';
    menu.appendChild(sep);
    state.bookmarks.forEach((bm) => {
      const item = document.createElement('div');
      item.className = 'bookmark-item';
      const hint = directoryPrefix(bm.path) || bm.path;
      item.innerHTML = `<span class="bm-name">${escapeHtml(bm.name)}</span><span class="bm-path">${escapeHtml(hint)}</span>`;
      item.addEventListener('click', () => {
        menu.classList.add('hidden');
        jumpTo(resolveVars(bm.path));
      });
      menu.appendChild(item);
    });
  }
}

function resolveVars(path) {
  const now = new Date();
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, '0');
  const d = String(now.getDate()).padStart(2, '0');
  const d1 = Math.floor(now.getDate() / 10);
  return path
    .replace('{YMD1}', `${y}${m}${d1}`)
    .replace('{YMD}', `${y}${m}${d}`)
    .replace('{YM}', `${y}${m}`)
    .replace('{Y}', `${y}`)
    .replace('{M}', `${m}`)
    .replace('{D1}', `${d1}`)
    .replace('{D}', `${d}`);
}

function jumpTo(path) {
  if (!state.selectedBucket) return;
  if (path.endsWith('/')) {
    clearFilterSilently();
    state.currentPrefix = path;
    updatePathInput();
    loadObjects(state.selectedBucket, path, { reset: true });
  } else {
    const dirPrefix = directoryPrefix(path);
    const filePrefix = path.slice(dirPrefix.length);
    clearFilterSilently();
    state.currentPrefix = dirPrefix;
    state.filterPattern = filePrefix;
    $('filterInput').value = filePrefix;
    updatePathInput();
    loadObjects(state.selectedBucket, dirPrefix + filePrefix, { reset: true });
  }
}

$('bookmarkBtn').addEventListener('click', (e) => {
  e.stopPropagation();
  const menu = $('bookmarkMenu');
  menu.classList.toggle('hidden');
  renderBookmarkMenu();
});
document.addEventListener('click', (e) => {
  if (!e.target.closest('#bookmarkBtn') && !e.target.closest('#bookmarkMenu')) {
    $('bookmarkMenu').classList.add('hidden');
  }
});

let draggingBookmarkRow = null;

function openBookmarkManager() {
  $('bookmarkList').innerHTML = '';
  state.bookmarks.forEach((bm, idx) => {
    const row = document.createElement('div');
    row.className = 'bookmark-row';
    row.draggable = true;
    row.innerHTML = `
      <span class="drag">☰</span>
      <div class="bm-inputs">
        <input class="name" value="${escapeHtml(bm.name)}" placeholder="名称" />
        <input class="path mono" value="${escapeHtml(bm.path)}" placeholder="路径" />
      </div>
      <button class="row-btn" data-del title="删除">🗑</button>`;
    row.querySelector('input.name').addEventListener('input', (e) => {
      bm.name = e.target.value;
      persistBookmarks();
    });
    row.querySelector('input.path').addEventListener('input', (e) => {
      bm.path = e.target.value;
      persistBookmarks();
    });
    row.querySelector('[data-del]').addEventListener('click', () => {
      state.bookmarks = state.bookmarks.filter((b) => b.id !== bm.id);
      persistBookmarks();
      openBookmarkManager();
    });
    row.addEventListener('dragstart', () => { draggingBookmarkRow = row; });
    row.addEventListener('dragover', (e) => { e.preventDefault(); });
    row.addEventListener('drop', (e) => {
      e.preventDefault();
      if (draggingBookmarkRow && draggingBookmarkRow !== row) {
        const list = [...$('bookmarkList').children];
        const fromIdx = list.indexOf(draggingBookmarkRow);
        const toIdx = list.indexOf(row);
        const moved = state.bookmarks.splice(fromIdx, 1)[0];
        state.bookmarks.splice(toIdx, 0, moved);
        persistBookmarks();
        openBookmarkManager();
      }
    });
    row.addEventListener('dragend', () => { draggingBookmarkRow = null; });
    $('bookmarkList').appendChild(row);
  });
  $('bookmarkModal').classList.remove('hidden');
}

$('bookmarkDone').addEventListener('click', () => $('bookmarkModal').classList.add('hidden'));
$('resetBookmarksBtn').addEventListener('click', async () => {
  try {
    await settingsSaveQueue;
    const defaults = await invoke('reset_bookmarks');
    state.bookmarks = defaults;
    state.settings.bookmarks = defaults;
    openBookmarkManager();
  } catch (e) {
    showAppError(e);
  }
});
$('addBookmarkBtn').addEventListener('click', () => {
  $('newBookmarkName').value = '';
  $('newBookmarkPath').value = '';
  $('addBookmarkSave').disabled = true;
  $('addBookmarkModal').classList.remove('hidden');
});
$('addBookmarkCancel').addEventListener('click', () => $('addBookmarkModal').classList.add('hidden'));
$('newBookmarkPath').addEventListener('input', (e) => {
  $('addBookmarkSave').disabled = !e.target.value;
});
$('addBookmarkSave').addEventListener('click', () => {
  const path = $('newBookmarkPath').value.trim();
  if (!path) return;
  if (state.bookmarks.some((b) => b.path === path)) return;
  const name = $('newBookmarkName').value.trim() || fileNameOf(path);
  state.bookmarks.unshift({ id: newUuid(), name, path });
  persistBookmarks();
  $('addBookmarkModal').classList.add('hidden');
  if (!$('bookmarkModal').classList.contains('hidden')) {
    openBookmarkManager();
  }
});

$('openBookmarksFileBtn').addEventListener('click', async () => {
  const p = await invoke('get_settings_file_path').catch(() => null);
  if (p) openPath(p);
});

$('reloadBookmarksBtn').addEventListener('click', async () => {
  try {
    await settingsSaveQueue;
    const s = await invoke('reload_settings');
    state.settings = s;
    state.bookmarks = s.bookmarks || [];
    openBookmarkManager();
  } catch (e) {
    showAppError(e);
  }
});

async function refreshSettingsThen(cb) {
  try {
    const s = await invoke('get_settings');
    state.settings = s;
    state.bookmarks = s.bookmarks || [];
    if (cb) cb();
  } catch { if (cb) cb(); }
}

// ─────────────────────────────────────────────────────────────
// Logs
// ─────────────────────────────────────────────────────────────
function buildLogRow(e) {
  const row = document.createElement('div');
  row.className = 'log-row';
  row.innerHTML = `
    <span class="ts">${escapeHtml(e.timestamp)}</span>
    <span class="log-badge ${escapeHtml(e.level)}">${escapeHtml(e.level)}</span>
    <span class="caption">[${escapeHtml(e.environment)}]</span>
    <span class="action">${escapeHtml(e.action)}</span>
    <span class="detail" title="${escapeHtml(e.detail)}">${escapeHtml(e.detail)}</span>`;
  row.addEventListener('contextmenu', (ev) => {
    ev.preventDefault();
    showContextMenu(ev.clientX, ev.clientY, [
      { label: '复制', action: () => copyText(e.line) },
    ]);
  });
  return row;
}

function renderLogs() {
  const level = $('logLevelFilter').value;
  const list = $('logList');
  list.innerHTML = '';
  const entries = level ? state.logEntries.filter((e) => e.level === level) : state.logEntries;
  const frag = document.createDocumentFragment();
  entries.forEach((e) => frag.appendChild(buildLogRow(e)));
  list.appendChild(frag);
}

// Incrementally prepend a single new entry without rebuilding the whole list.
function appendLogEntry(e) {
  const level = $('logLevelFilter').value;
  if (level && e.level !== level) return;
  const list = $('logList');
  list.insertBefore(buildLogRow(e), list.firstChild);
  while (list.childElementCount > 1000) {
    list.removeChild(list.lastElementChild);
  }
}

$('logLevelFilter').addEventListener('change', renderLogs);
$('clearLogsBtn').addEventListener('click', async () => {
  state.logEntries = [];
  renderLogs();
  await invoke('clear_logs').catch(console.error);
});
$('openLogBtn').addEventListener('click', async () => {
  const p = await invoke('get_log_file_path').catch(() => null);
  if (p) revealPath(p);
});
$('logToggleBtn').addEventListener('click', () => {
  const collapsed = $('logPanel').classList.toggle('collapsed');
  $('logToggleBtn').textContent = collapsed ? '▴' : '▾';
  $('logResizeHandle').classList.toggle('hidden', collapsed);
});

// ── Resizable log panel ──
const LOG_MIN = 40;
const LOG_MAX = 800;
let logHeight = 150;
$('logList').style.height = logHeight + 'px';

$('logResizeHandle').addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  e.preventDefault();
  const startY = e.clientY;
  const startH = $('logList').getBoundingClientRect().height;
  $('logResizeHandle').classList.add('active');
  const onMove = (ev) => {
    logHeight = Math.min(LOG_MAX, Math.max(LOG_MIN, startH + (startY - ev.clientY)));
    $('logList').style.height = logHeight + 'px';
    ev.preventDefault();
  };
  const onUp = () => {
    $('logResizeHandle').classList.remove('active');
    document.removeEventListener('mousemove', onMove);
    document.removeEventListener('mouseup', onUp);
  };
  document.addEventListener('mousemove', onMove);
  document.addEventListener('mouseup', onUp);
});

// ─────────────────────────────────────────────────────────────
// Context menu
// ─────────────────────────────────────────────────────────────
function showContextMenu(x, y, items) {
  const menu = $('contextMenu');
  menu.innerHTML = '';
  items.forEach((item) => {
    if (item.sep) {
      const sep = document.createElement('div');
      sep.className = 'cm-sep';
      menu.appendChild(sep);
      return;
    }
    const el = document.createElement('div');
    el.className = 'cm-item';
    el.textContent = item.label;
    el.addEventListener('click', () => {
      menu.classList.add('hidden');
      item.action();
    });
    menu.appendChild(el);
  });
  menu.classList.remove('hidden');
  const rect = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, window.innerWidth - rect.width - 8) + 'px';
  menu.style.top = Math.min(y, window.innerHeight - rect.height - 8) + 'px';
}

document.addEventListener('click', (e) => {
  if (!e.target.closest('#contextMenu')) $('contextMenu').classList.add('hidden');
});
document.addEventListener('contextmenu', (e) => {
  if (!e.target.closest('#fileBody') && !e.target.closest('.bucket-item') && !e.target.closest('#logList')) {
    // allow default for other areas
  }
});

async function copySelectedNames() {
  const names = state.objects
    .filter((o) => state.selectedObjects.has(o.key))
    .map((o) => o.display_name)
    .join('\n');
  await copyText(names);
}

async function copySelectedPaths() {
  await copyText([...state.selectedObjects].join('\n'));
}

// ─────────────────────────────────────────────────────────────
// Settings modal
// ─────────────────────────────────────────────────────────────
$('settingsBtn').addEventListener('click', openSettings);
$('settingsClose').addEventListener('click', () => $('settingsModal').classList.add('hidden'));

function openSettings() {
  $('settingsModal').classList.remove('hidden');
  renderSettingsTab('profiles');
}
document.querySelectorAll('.settings-tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.settings-tab').forEach((t) => t.classList.remove('active'));
    tab.classList.add('active');
    renderSettingsTab(tab.dataset.tab);
  });
});

let settingsSaveQueue = Promise.resolve();
let settingsSaveVersion = 0;
function persistSettings() {
  const settings = JSON.parse(JSON.stringify(state.settings));
  const version = ++settingsSaveVersion;
  settingsSaveQueue = settingsSaveQueue.then(async () => {
    try {
      await invoke('save_settings', { settings });
    } catch (error) {
      showAppError({ title: '设置保存失败', message: String(error), suggestion: '请检查配置目录权限和磁盘空间。' });
      if (version === settingsSaveVersion) {
        try {
          const saved = await invoke('get_settings');
          if (version !== settingsSaveVersion) return;
          state.settings = saved;
          state.bookmarks = saved.bookmarks || [];
          renderBookmarkMenu();
          if (!$('bookmarkModal').classList.contains('hidden')) openBookmarkManager();
          const tab = document.querySelector('.settings-tab.active');
          if (tab) renderSettingsTab(tab.dataset.tab);
        } catch (reloadError) {
          showAppError(reloadError);
        }
      }
    }
  });
  return settingsSaveQueue;
}

function updateSetting(mutator) {
  mutator(state.settings);
  persistSettings();
}

function renderSettingsTab(tab) {
  const body = $('settingsBody');
  if (tab === 'profiles') {
    renderProfilesTab(body);
  } else if (tab === 'download') {
    renderDownloadTab(body);
  } else {
    renderAboutTab(body);
  }
}

function renderProfilesTab(body) {
  let html = `<div class="config-doc">`;
  html += `<p class="settings-note">配置文件：<b>~/.aws/s3tools</b></p>`;
  html += `<p class="settings-note">共 ${state.profiles.length} 个环境（全部来自配置文件，不可在此编辑）</p>`;
  state.profiles.forEach((p) => {
    const masked = p.access_key_id ? `${p.access_key_id.slice(0, 4)}••••••••${p.access_key_id.slice(-4)}` : '';
    html += `<div class="profile-row">
      <span class="pr-name">${p.is_production ? '☁' : '🖥'} ${escapeHtml(p.name)}</span>
      ${p.is_production ? '<span class="pr-badge">🔒 生产</span>' : ''}
      <div class="pr-grid">
        <span>Region: ${escapeHtml(p.region)}</span>
        ${p.endpoint ? `<span>Endpoint: ${escapeHtml(p.endpoint)}</span>` : ''}
        ${p.use_path_style ? '<span>Path-style: 已开启</span>' : ''}
        <span>Access Key: ${escapeHtml(masked)}</span>
      </div>
    </div>`;
  });
  html += `<code class="block">[default]
region = ap-southeast-1          # 全局默认 region（可省略）

[my-offline]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
endpoint = http://minio:9000     # MinIO/LocalStack 自定义地址；留空=AWS 标准
region = us-east-1               # 留空则继承 [default]
path_style = true                # MinIO 需要开启；AWS S3 无需
default_bucket = my-data-bucket  # 启动自动连接的 Bucket（可省略）</code>`;
  html += `<h4>生产环境自动判断</h4>`;
  html += `<p class="settings-note">名称含 prod / production / live / online / prd → 自动标记为生产（禁止上传）</p>`;
  html += `<p class="settings-note">用 is_production = false 可强制覆盖自动判断结果</p>`;
  html += `</div>`;
  body.innerHTML = html;
}

function renderDownloadTab(body) {
  body.innerHTML = '';
  const s = state.settings;

  body.appendChild(makeStepperRow('最大并发数', s.max_concurrent_downloads, 1, 16, 1, (v) => {
    updateSetting((ss) => { ss.max_concurrent_downloads = v; });
  }));
  body.appendChild(makeDirRow('下载目录', s.download_directory, async (path) => {
    updateSetting((ss) => { ss.download_directory = path; });
  }));
  body.appendChild(makeToggleRow('校验 MD5 (ETag)', s.checksum_enabled, (v) => {
    updateSetting((ss) => { ss.checksum_enabled = v; });
  }));
  body.appendChild(makeSelectRow('同名文件', s.conflict_policy, [
    { value: 'overwrite', label: '覆盖' },
    { value: 'skip', label: '跳过' },
    { value: 'rename', label: '自动重命名' },
  ], (v) => {
    updateSetting((ss) => { ss.conflict_policy = v; });
  }));
  body.appendChild(makeStepperRow('每页条数', s.page_size, 50, 1000, 50, (v) => {
    updateSetting((ss) => { ss.page_size = v; });
  }));
  body.appendChild(makeStepperRow('补全缓存有效期 (秒)', s.completion_cache_ttl, 10, 600, 10, (v) => {
    updateSetting((ss) => { ss.completion_cache_ttl = v; });
  }));
}

function makeStepperRow(label, value, min, max, step, onChange) {
  const row = document.createElement('div');
  row.className = 'settings-row';
  const inp = document.createElement('input');
  inp.type = 'number';
  inp.min = min; inp.max = max; inp.step = step;
  inp.value = value;
  inp.style.width = '80px';
  inp.style.padding = '4px 6px';
  inp.style.border = '1px solid var(--border)';
  inp.style.borderRadius = '4px';
  inp.style.background = 'var(--bg)';
  inp.style.color = 'var(--text)';
  inp.style.textAlign = 'right';
  inp.addEventListener('change', () => {
    let v = parseInt(inp.value, 10) || min;
    v = Math.max(min, Math.min(max, v));
    inp.value = v;
    onChange(v);
  });
  const lbl = document.createElement('label');
  lbl.textContent = label;
  row.appendChild(lbl);
  row.appendChild(inp);
  return row;
}

function makeDirRow(label, value, onChange) {
  const row = document.createElement('div');
  row.className = 'settings-row';
  const lbl = document.createElement('label');
  lbl.textContent = label;
  const wrap = document.createElement('div');
  wrap.style.cssText = 'display:flex;align-items:center;gap:6px;max-width:60%;';
  const txt = document.createElement('span');
  txt.className = 'settings-note mono';
  txt.textContent = value;
  txt.style.cssText = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
  const btn = document.createElement('button');
  btn.className = 'text-btn';
  btn.textContent = '选择...';
  btn.addEventListener('click', async () => {
    const p = await dialog.open({ directory: true, multiple: false });
    if (typeof p === 'string') {
      txt.textContent = p;
      onChange(p);
    }
  });
  wrap.appendChild(txt);
  wrap.appendChild(btn);
  row.appendChild(lbl);
  row.appendChild(wrap);
  return row;
}

function makeToggleRow(label, value, onChange) {
  const row = document.createElement('div');
  row.className = 'settings-row';
  const lbl = document.createElement('label');
  lbl.textContent = label;
  const chk = document.createElement('input');
  chk.type = 'checkbox';
  chk.checked = value;
  chk.addEventListener('change', () => onChange(chk.checked));
  row.appendChild(lbl);
  row.appendChild(chk);
  return row;
}

function makeSelectRow(label, value, options, onChange) {
  const row = document.createElement('div');
  row.className = 'settings-row';
  const lbl = document.createElement('label');
  lbl.textContent = label;
  const sel = document.createElement('select');
  sel.className = 'mini-select';
  options.forEach((opt) => {
    const o = document.createElement('option');
    o.value = opt.value;
    o.textContent = opt.label;
    if (opt.value === value) o.selected = true;
    sel.appendChild(o);
  });
  sel.addEventListener('change', () => onChange(sel.value));
  row.appendChild(lbl);
  row.appendChild(sel);
  return row;
}

function renderAboutTab(body) {
  body.innerHTML = `
    <div style="text-align:center;padding-top:20px;">
      <div style="font-size:44px;">🛢</div>
      <h2 style="margin-top:8px;">S3 Rust</h2>
      <p class="caption">版本 1.0.1</p>
      <p class="caption" style="margin-top:8px;">一个跨平台 S3 图形化工具<br/>支持多环境、批量下载、路径自动补全</p>
      <div class="error-divider" style="margin:16px 0;"></div>
      <p class="caption">日志文件位置</p>
      <p class="caption mono" id="aboutLogPath"></p>
    </div>`;
  invoke('get_log_file_path').then((p) => {
    $('aboutLogPath').textContent = p;
  }).catch(() => {});
}

// ─────────────────────────────────────────────────────────────
// Error modal
// ─────────────────────────────────────────────────────────────
$('errorOk').addEventListener('click', closeError);
$('errorLog').addEventListener('click', async () => {
  closeError();
  const p = await invoke('get_log_file_path').catch(() => null);
  if (p) revealPath(p);
});

// ─────────────────────────────────────────────────────────────
// Keyboard shortcuts
// ─────────────────────────────────────────────────────────────
const IS_MAC = /Mac|iPhone|iPod|iPad/.test(navigator.platform || navigator.userAgent);
const modKey = (e) => (IS_MAC ? e.metaKey : e.ctrlKey) && !e.altKey;
const MOD_LABEL = IS_MAC ? '⌘' : 'Ctrl';

$('refreshBtn').title = `强制刷新，忽略缓存 (${MOD_LABEL}R)`;
$('settingsBtn').title = `设置 (${MOD_LABEL}+,)`;

document.addEventListener('keydown', (e) => {
  if (modKey(e) && e.key.toLowerCase() === 'r') {
    e.preventDefault();
    $('refreshBtn').click();
  }
  if (modKey(e) && e.key.toLowerCase() === 'd') {
    e.preventDefault();
    if (state.selectedObjects.size) downloadSelected();
  }
  if (modKey(e) && (e.key === ',' || e.key === '<')) {
    e.preventDefault();
    openSettings();
  }
  if (e.key === 'Escape') {
    closeError();
    $('regexModal').classList.add('hidden');
    $('bookmarkModal').classList.add('hidden');
    $('addBookmarkModal').classList.add('hidden');
    $('settingsModal').classList.add('hidden');
    $('contextMenu').classList.add('hidden');
    $('bookmarkMenu').classList.add('hidden');
    hideCompletions();
  }
});

// kick off
init();
