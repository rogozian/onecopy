import { detectDuplicates, formatSize } from './scan-engine.mjs';

const el = id => document.getElementById(id);
let source = 'photos';
let sourceEntries = [];
let nextId = 1;
let currentResult = null;
let controller = null;
let keeperIds = new Map();
let ignored = new Set();
let currentUrls = [];
let appendMode = false;

function show(id, visible) { el(id).classList.toggle('hidden', !visible); }
function sourceSelect(value) {
  source = value;
  el('source-photos').classList.toggle('selected', value === 'photos');
  el('source-files').classList.toggle('selected', value === 'files');
  el('scan-description').textContent = value === 'photos'
    ? 'Нажми и выбери фотографии или видео для проверки.'
    : 'Нажми и выбери документы или другие файлы.';
}
function selectFiles() { if (!controller) { el(source === 'photos' ? 'photos-picker' : 'files-picker').click(); } }
async function beginScan(files) {
  if (!files?.length) return;
  const chosen = Array.from(files, f => ({ id: nextId++, file: f, path: f.webkitRelativePath || f.name }));
  sourceEntries = appendMode ? sourceEntries.concat(chosen) : chosen;
  appendMode = false;
  await analyze();
}
function progress({ phase, completed, total }) {
  const percent = Math.round(completed / (total || 1) * 100);
  el('status-percent').textContent = percent + '%';
  el('progress-fill').style.width = `${percent}%`;
  el('scanner-frame').style.setProperty('--progress', percent);
  el('status-title').textContent = phase === 'sample' ? 'Ищем совпадения' : 'Сверяем каждый байт';
  el('status-details').textContent = phase === 'sample' ? 'Проверяем размеры и цифровые отпечатки' : 'Подтверждаем полное совпадение содержимого';
}
async function analyze() {
  if (controller) controller.abort();
  controller = new AbortController();
  const taskController = controller;
  show('scan-status', true); show('results', false); show('plan', false);
  el('scanner-frame').classList.add('is-running');
  el('scan-button-subtitle').textContent = 'Идёт проверка…';
  el('scan-btn').disabled = true;
  el('progress-fill').style.width = '0%';
  el('status-percent').textContent = '0%';
  el('status-title').textContent = 'Начинаем проверку';
  el('status-details').textContent = 'Файлы остаются только на твоём устройстве';
  try {
    const result = await detectDuplicates(sourceEntries, { signal: taskController.signal, onProgress: progress });
    if (taskController.signal.aborted) return;
    currentResult = result;
    keeperIds = new Map(result.groups.map(g => [g.id, g.entries[0].id]));
    ignored.clear();
    renderResults();
    show('scan-status', false); show('results', true);
    el('results').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (error) {
    if (error.name !== 'AbortError') {
      el('status-title').textContent = 'Проверка прервана';
      el('status-details').textContent = 'Не удалось прочитать часть файлов. Попробуй снова.';
    }
  } finally {
    if (controller === taskController) {
      controller = null;
      el('scanner-frame').classList.remove('is-running');
      el('scan-button-subtitle').textContent = 'Нажми, чтобы начать';
      el('scan-btn').disabled = false;
    }
  }
}
function clearObjectUrls() {
  for (const url of currentUrls) URL.revokeObjectURL(url);
  currentUrls = [];
}
function makeThumb(entry) {
  const wrap = document.createElement('div'); wrap.className = 'copy-thumb';
  if (entry.file.type.startsWith('image/')) {
    const img = document.createElement('img');
    const url = URL.createObjectURL(entry.file); currentUrls.push(url);
    img.src = url; img.alt = ''; img.className = 'copy-thumb'; img.loading = 'lazy';
    wrap.append(img);
  } else {
    wrap.textContent = entry.file.type.startsWith('video/') ? '▶' : '▤';
  }
  return wrap;
}
function renderResults() {
  if (!currentResult) return;
  clearObjectUrls();
  el('stat-files').textContent = currentResult.scanned.toLocaleString('ru-RU');
  el('stat-copies').textContent = currentResult.duplicates.toLocaleString('ru-RU');
  el('stat-space').textContent = formatSize(currentResult.duplicatedBytes);
  el('results-headline').textContent = currentResult.groups.length ? `Найдены дубли` : 'Дубликатов нет';
  show('results-empty', currentResult.groups.length === 0);
  show('result-actions', currentResult.groups.length > 0);
  const container = el('groups'); container.replaceChildren();
  for (const [index, group] of currentResult.groups.entries()) {
    if (ignored.has(group.id)) continue;
    const article = document.createElement('article'); article.className = 'duplicate-group';
    const head = document.createElement('button');
    head.className = 'group-toggle';head.type = 'button';head.setAttribute('aria-expanded', index === 0 ? 'true' : 'false');
    head.innerHTML = `<span class="group-counter">${group.entries.length}</span><span class="group-main"><strong>Группа ${index + 1} · точные копии</strong><span>${formatSize(group.bytes)} каждый · ${formatSize(group.bytes * (group.entries.length-1))} повторов</span></span><span class="fold">${index === 0 ? '−' : '+'}</span>`;
    const body = document.createElement('div');body.className = 'group-contents';
    if (index !== 0) body.classList.add('hidden');
    head.addEventListener('click', () => {
      const open = body.classList.toggle('hidden') === false;
      head.setAttribute('aria-expanded', String(open));head.querySelector('.fold').textContent = open ? '−' : '+';
    });
    const hint = document.createElement('p');hint.className = 'group-help';hint.textContent = 'Выбери единственный экземпляр, который нужно сохранить:';body.append(hint);
    for (const entry of group.entries) {
      const label = document.createElement('label');label.className = 'copy-option';
      if (keeperIds.get(group.id) === entry.id) label.classList.add('is-keeper');
      const radio = document.createElement('input');radio.type = 'radio';radio.name = `keeper-${group.id}`;radio.checked = keeperIds.get(group.id) === entry.id;
      const indicator = document.createElement('span');indicator.className = 'copy-radio';
      const name = document.createElement('span');name.className = 'copy-label';
      const title = document.createElement('strong');title.textContent = entry.file.name;
      const detail = document.createElement('span'); detail.textContent = `${formatSize(entry.file.size)} · ${new Date(entry.file.lastModified || Date.now()).toLocaleDateString('ru-RU')}`;
      name.append(title, detail);
      const state = document.createElement('span');state.className = 'copy-keeper';state.textContent = radio.checked ? 'ОСТАВИТЬ' : '';
      label.append(radio, indicator, makeThumb(entry), name, state);
      radio.addEventListener('change', () => {
        keeperIds.set(group.id, entry.id);
        for (const sibling of body.querySelectorAll('.copy-option')) {
          sibling.classList.toggle('is-keeper', sibling === label);
          sibling.querySelector('.copy-keeper').textContent = sibling === label ? 'ОСТАВИТЬ' : '';
        }
      });
      body.append(label);
    }
    article.append(head, body);container.append(article);
  }
  if (currentResult.errors.length) {
    el('read-errors').textContent = `Не удалось проверить ${currentResult.errors.length} файл(ов). Они не включены в результат.`;
    show('read-errors',true);
  } else show('read-errors',false);
}
function generatePlan() {
  const list = [];
  for (const group of currentResult?.groups || []) {
    if (ignored.has(group.id)) continue;
    const keepId = keeperIds.get(group.id);
    list.push({ group, keep: group.entries.find(e => e.id === keepId) || group.entries[0], duplicates: group.entries.filter(e => e.id !== keepId) });
  }
  return list;
}
function renderPlan() {
  const list = generatePlan();
  const container = el('plan-items');container.replaceChildren();
  for (const [i, item] of list.entries()) {
    const block = document.createElement('div');block.className = 'plan-list';
    const heading = document.createElement('strong');heading.textContent = `Группа ${i+1} · ${formatSize(item.group.bytes)}`;
    const keep = document.createElement('p');keep.className = 'plan-keep';keep.textContent = `✓ Сохранить: ${item.keep.path}`;
    block.append(heading,keep);
    for (const entry of item.duplicates) {
      const line = document.createElement('p');line.className = 'plan-delete';line.textContent = `○ Проверить для ручного удаления: ${entry.path}`;block.append(line);
    }
    container.append(block);
  }
  show('plan', true);el('plan').scrollIntoView({ behavior:'smooth', block:'start' });
}
function planText() {
  const lines = ['ONECOPY · План ручной проверки дубликатов', 'Файлы НЕ удалены.', ''];
  for (const [i, item] of generatePlan().entries()) {
    lines.push(`Группа ${i+1}, ${formatSize(item.group.bytes)}`);
    lines.push(`СОХРАНИТЬ: ${item.keep.path}`);
    for (const entry of item.duplicates) lines.push(`ПРОВЕРИТЬ ПЕРЕД УДАЛЕНИЕМ: ${entry.path}`);
    lines.push('');
  }
  lines.push('Важно: названия могут совпадать, а Safari может не показывать исходный путь. Сверяй файлы вручную.');
  return lines.join('\n');
}
function csv(v) { return '"' + String(v).replace(/"/g, '""') + '"'; }
function downloadReport() {
  const rows = [['Группа', 'Действие', 'Имя', 'Путь, если доступен', 'Байт', 'Дата изменения']];
  for (const [i, item] of generatePlan().entries()) for (const entry of item.group.entries) {
    rows.push([i + 1, entry.id === item.keep.id ? 'СОХРАНИТЬ' : 'ПРОВЕРИТЬ ДЛЯ РУЧНОГО УДАЛЕНИЯ', entry.file.name,entry.path,entry.file.size,new Date(entry.file.lastModified||0).toISOString()]);
  }
  const file = new Blob(['\uFEFF', rows.map(row=>row.map(csv).join(';')).join('\r\n')], {type:'text/csv;charset=utf-8'});
  const url=URL.createObjectURL(file);const a=document.createElement('a');a.href=url;a.download='ONECOPY-duplicates.csv';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);
}

el('source-photos').addEventListener('click',()=>sourceSelect('photos'));
el('source-files').addEventListener('click',()=>sourceSelect('files'));
el('scan-btn').addEventListener('click',()=>{appendMode=false;selectFiles();});
el('photos-picker').addEventListener('change',e=>{ void beginScan(e.target.files);e.target.value=''; });
el('files-picker').addEventListener('change',e=>{ void beginScan(e.target.files);e.target.value=''; });
el('cancel-btn').addEventListener('click',()=>{controller?.abort();show('scan-status',false);});
el('prepare-btn').addEventListener('click',renderPlan);
el('add-more-btn').addEventListener('click',()=>{appendMode=true;selectFiles();});
el('copy-plan').addEventListener('click',async()=>{
  try { await navigator.clipboard.writeText(planText());el('copy-plan').textContent='✓ Список скопирован';setTimeout(()=>{el('copy-plan').textContent='Скопировать список';},2500); }
  catch { el('copy-plan').textContent='Копирование недоступно'; }
});
el('download-plan').addEventListener('click',downloadReport);
if ('serviceWorker' in navigator && location.protocol.startsWith('http')) {
  window.addEventListener('load',()=>navigator.serviceWorker.register('./sw.js').catch(()=>{}));
}
