import { CATS, RARITIES, MODES, createState, restoreState, newTicket, openRegion, claimTicket, toggleFavorite, ScratchCoverage } from './collection.mjs';

const SAVE_KEY = 'gamebox.cat-scratch.v1';
const $ = selector => document.querySelector(selector);
const app = $('#app');
const dialog = $('#detail-dialog');
let state;
let saveBlocked = false;
let conflict = false;
let page = 'scratch';
let filter = 'all';
let onlyOwned = false;
let cleanupScratch = () => {};
let toastTimer;
let soundContext;
let scratchBuffer;
let lastSound = 0;
let exporting = false;

function storageWarning(message) {
  const banner = $('#storage-warning');
  banner.hidden = false;
  banner.textContent = message;
}
try { state = restoreState(localStorage.getItem(SAVE_KEY)); }
catch {
  state = createState();
  saveBlocked = true;
  storageWarning('无法读取收藏存档。本次可临时试玩，但进度不会保存；原存档不会被覆盖。请检查浏览器存储设置。');
}

function save() {
  if (saveBlocked || conflict) return;
  try { localStorage.setItem(SAVE_KEY, JSON.stringify(state)); }
  catch {
    saveBlocked = true;
    storageWarning('浏览器未能保存收藏。本次进度暂留在此页面，请不要关闭或刷新；检查存储空间与浏览器设置后再试。');
  }
}

window.addEventListener('storage', event => {
  if (event.key !== SAVE_KEY && event.key !== null) return;
  conflict = true;
  cleanupScratch();
  dialog.close();
  storageWarning('另一个页面更新了收藏。为避免覆盖，已暂停操作；请刷新此页，读取最新进度。');
  app.querySelectorAll('button').forEach(button => { button.disabled = true; });
});

function toast(message) {
  clearTimeout(toastTimer);
  $('#toast').textContent = message;
  $('#toast').hidden = false;
  toastTimer = setTimeout(() => { $('#toast').hidden = true; }, 2800);
}

function art(cat, extra = '') {
  // Generated artwork has hand-laid row boundaries. Use measured atlas bounds
  // rather than assuming equal rows and cutting off hats or leaking neighbors.
  const rows = [0, 304, 576, 838, 1096, 1319, 1536];
  const row = Math.floor(cat.index / 4), height = rows[row + 1] - rows[row];
  const x = cat.index % 4 / 3 * 100, y = rows[row] / (1536 - height) * 100;
  return `<div class="cat-art ${extra}" style="--sprite-x:${x}%;--sprite-y:${y}%;--sprite-height:${1536 / height * 100}%" role="img" aria-label="${cat.job}${cat.name}"></div>`;
}

function badge(cat) { return `<div class="badge-art rim-${cat.rarity}">${art(cat)}</div>`; }
function rarity(cat) { const r = RARITIES[cat.rarity]; return `<span class="rarity rarity-${r.id}">${r.symbol} ${r.name}</span>`; }
function collected() { return Object.keys(state.collection).length; }
function rarityCounts() {
  return RARITIES.map(r => {
    const pool = CATS.filter(cat => cat.rarity === r.id);
    return `<div><span>${r.symbol} ${r.name}</span><strong>${pool.filter(c => state.collection[c.id]).length} / ${pool.length}</strong></div>`;
  }).join('');
}

function heading(title, subtitle, label = 'VOL. 01 / CATS AT WORK') {
  return `<div class="page-heading"><div><div class="eyebrow">${label}</div><h1>${title}</h1><p>${subtitle}</p></div><div class="series-stamp">猫猫百业<strong>24</strong>待你收集</div></div>`;
}

function updateHeader() {
  document.documentElement.dataset.theme = state.theme;
  $('#nav-count').textContent = collected();
  document.querySelectorAll('[data-page]').forEach(button => button.classList.toggle('selected', button.dataset.page === page));
  $('#sound-toggle').innerHTML = `♫<span>声音${state.sound ? '开' : '关'}</span>`;
  $('#sound-toggle').title = state.sound ? '关闭声音' : '开启声音';
  $('#sound-toggle').setAttribute('aria-pressed', String(state.sound));
  $('#theme-toggle').textContent = state.theme === 'light' ? '☾' : '☀';
}

function render() {
  cleanupScratch();
  cleanupScratch = () => {};
  updateHeader();
  if (page === 'album') renderAlbum();
  else if (page === 'showcase') renderShowcase();
  else renderScratch();
  if (conflict) app.querySelectorAll('button').forEach(button => { button.disabled = true; });
}

function renderScratch() {
  if (!state.ticket) { newTicket(state); save(); }
  const t = state.ticket, cat = CATS.find(c => c.id === t.catId), mode = MODES[t.mode];
  const owned = collected();
  app.innerHTML = `${heading('每一刮，遇见一只新朋友。', '把一点点好运，变成一整本可爱。')}
    <div class="scratch-layout">
      <aside class="left-sidebar"><div class="side-title">今天，怎么刮？ <span>01 — 03</span></div>
        <div class="mode-list">${Object.entries(MODES).map(([id, m], i) => `<button class="mode ${t.mode === id ? 'selected' : ''}" data-mode="${id}" aria-pressed="${t.mode === id}"><span class="mode-icon">${['▧', '✿', '▤'][i]}</span><span><strong>${m.name}</strong><small>${m.subtitle}</small></span></button>`).join('')}</div>
        <div class="hand-note"><strong>不用赶，好运慢慢来。</strong>用手指或鼠标涂一涂，<br>猫猫就藏在银色涂层下面。<br><br>三种刮法，同一个奖池。<br>每一张都免费，每一只都可爱。</div>
      </aside>
      <section class="play-column">
        <div class="stage"><div class="stage-top"><span>SCRATCH A LITTLE JOY</span><span>无限畅刮 ∞</span></div>
          <article class="ticket ${t.claimed ? 'revealed' : ''}" id="ticket" data-mode="${t.mode}" data-claimed="${t.claimed}">
            <div class="ticket-header"><strong>猫 猫 百 业</strong><small>COLLECTION 01<br>GOOD THINGS INSIDE</small></div>
            ${t.mode === 'career' ? `<div class="career-clue"><span>${cat.clue}</span>${t.opened.includes('clue') ? '' : '<canvas class="scratch" data-region="clue"></canvas>'}</div>` : ''}
            <div class="art-window">${art(cat)}
              ${t.claimed ? '' : t.mode === 'career' && !t.opened.includes('clue') ? '<div class="locked-portrait"><b>♧</b><span>先刮上方的职业线索</span></div>' :
                `<div class="scratch-overlay ${t.mode === 'paws' ? '' : 'single'}">${(t.mode === 'paws' ? ['0', '1', '2', '3'] : ['portrait']).map(region => `<canvas class="scratch ${t.opened.includes(region) ? 'opened' : ''}" data-region="${region}"></canvas>`).join('')}</div>`}
            </div>
            <div class="ticket-result" id="ticket-result">${t.claimed ? resultMarkup(cat) : `<h2>${mode.name}</h2><p>${t.mode === 'career' && t.opened.includes('clue') ? '有头绪了吗？刮开照片见见它。' : '这一次，会遇见怎样的猫猫？'}</p>`}</div>
            <div class="ticket-footer"><span>NO. ${String(t.id).padStart(6, '0')}</span><span>一张小票 · 一份小确幸</span></div>
          </article>
          <div class="scratch-help"><span id="scratch-label">${t.claimed ? '已自动收入图鉴' : '用手指或鼠标，慢慢刮开'}</span><div class="progress-track"><i id="scratch-progress" style="width:${t.claimed ? 100 : 0}%"></i></div></div>
        </div>
        <div class="play-actions">${t.claimed ? `<button class="secondary" data-detail="${cat.id}">看看这只猫</button><button class="primary" id="next-ticket">再来一张 ↗</button>` : '<button class="secondary" id="reveal-all">全部刮开</button><button class="primary" disabled>刮开，迎接小惊喜</button>'}</div>
      </section>
      <aside class="right-sidebar"><div class="collection-summary"><div class="side-title">我的收藏手账 <span>VOL. 01</span></div><div class="collection-number">${owned}<small> / 24</small></div><div class="progress-track"><i style="width:${owned / 24 * 100}%"></i></div><p>${owned ? `已经和 ${owned} 只猫猫成为朋友。` : '第一位猫猫朋友，正在等你。'}</p><div class="rarity-counts">${rarityCounts()}</div><button class="text-button" data-go="album">翻开图鉴 →</button></div>
        <div class="featured"><div class="eyebrow">本册珍藏 · 传说</div><button data-detail="cat-24">${badge(CATS[23])}<strong>星愿收藏家 · 星弥</strong></button><p>把小小的愿望，收成满天星光。</p></div>
      </aside>
    </div>
    <div class="series-bar"><div><strong>猫猫百业 · 第一册</strong><p class="muted">24 个小小职业，24 种认真生活。</p></div><div class="mini-cats">${[0, 12, 19].map(i => badge(CATS[i])).join('')}<span>+21</span></div><button class="text-button" data-go="album">${owned}/24 · 去收集 →</button></div>`;
  if (!t.claimed && !conflict) mountScratch();
}

function resultMarkup(cat, isNew) {
  const item = state.collection[cat.id];
  return `<span class="result-tag">${isNew ?? item.count === 1 ? '✦ 新朋友，已点亮图鉴' : `又见面啦 · 已收藏 ×${item.count}`}</span><h2>${cat.job} · ${cat.name}</h2><p>${RARITIES[cat.rarity].symbol} ${RARITIES[cat.rarity].name} · NO. ${String(cat.index + 1).padStart(3, '0')}</p>`;
}

function renderAlbum() {
  const visible = CATS.filter(cat => (filter === 'all' || cat.rarity === Number(filter)) && (!onlyOwned || state.collection[cat.id]));
  app.innerHTML = `${heading('每一只，都值得被珍藏。', `已遇见 ${collected()} / 24 只猫猫 · 共刮开 ${state.total} 张小惊喜`, 'MY COLLECTION / 猫猫图鉴')}
    <div class="filter-row"><button data-filter="all" class="${filter === 'all' ? 'selected' : ''}">全部 · 24</button>${RARITIES.map(r => `<button data-filter="${r.id}" class="${filter === String(r.id) ? 'selected' : ''}">${r.symbol} ${r.name} · ${CATS.filter(c => c.rarity === r.id).length}</button>`).join('')}<button class="owned-filter ${onlyOwned ? 'selected' : ''}" id="owned-filter" aria-pressed="${onlyOwned}">${onlyOwned ? '✓ ' : ''}只看已拥有</button></div>
    ${visible.length ? `<div class="album-grid">${visible.map(cat => {
      const item = state.collection[cat.id];
      return `<button class="album-card ${item ? '' : 'unowned'}" data-detail="${cat.id}"><span class="catalog-number">NO. ${String(cat.index + 1).padStart(3, '0')}</span>${state.favorites.includes(cat.id) ? '<span class="card-pin">✦</span>' : ''}${item ? badge(cat) : '<div class="unknown-badge">?</div>'}<strong>${item ? cat.job : '等待相遇'}</strong>${rarity(cat)}<small>${item ? `${cat.name} · 拥有 ×${item.count}` : '点开看看收藏预览'}</small></button>`;
    }).join('')}</div>` : '<div class="empty">这里还没有猫猫。<br>刮开一张小票，开始收集吧。<br><button class="text-button" data-go="scratch">去刮一张 →</button></div>'}`;
}

function renderShowcase() {
  app.innerHTML = `${heading('把喜欢的猫猫，摆在一起。', '挑选六位猫猫朋友，布置你的专属小展柜。', 'MY LITTLE GALLERY / 我的展柜')}
    <section class="showcase-board"><div class="board-heading"><div class="eyebrow">CAT & LITTLE WONDERS</div><h2>我的猫猫收藏</h2><p>猫猫百业 · VOL. 01</p></div><div class="showcase-grid">${Array.from({ length: 6 }, (_, i) => {
      const cat = CATS.find(c => c.id === state.favorites[i]);
      return cat ? `<button class="showcase-slot" data-detail="${cat.id}">${badge(cat)}<strong>${cat.job} · ${cat.name}</strong>${rarity(cat)}</button>` : '<button class="showcase-slot" data-go="album"><span class="slot-plus">＋</span><small>从图鉴挑一只</small></button>';
    }).join('')}</div><div class="board-footer"><span>图鉴进度 <strong>${collected()} / 24</strong></span><span>已刮开 ${state.total} 张 · 展出 ${state.favorites.length} / 6</span></div></section>
    <div class="showcase-controls"><button class="secondary" data-go="album">挑选猫猫</button><button class="primary" id="export-card" ${state.favorites.length ? '' : 'disabled'}>保存展示卡 ↓</button></div><p class="showcase-note">展示卡保存在你的设备，分享给朋友比比收藏进度。</p>`;
}

function showCat(id) {
  const cat = CATS.find(c => c.id === id);
  if (!cat) return;
  const item = state.collection[id];
  const first = item ? new Intl.DateTimeFormat('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(item.first)) : '';
  $('#dialog-content').innerHTML = `<div class="dialog-top"><span class="eyebrow">${item ? '已收藏 · 徽章与原画' : '收藏预览 · 尚未获得'} / ${String(cat.index + 1).padStart(3, '0')}</span><button class="icon-button" data-close title="关闭">×</button></div><div class="detail-art">${art(cat)}</div><div class="detail-title"><h2>${cat.job} <small>· ${cat.name}</small></h2>${rarity(cat)}</div><p class="detail-story">${cat.story}</p><div class="detail-meta"><span>${item ? `首次相遇 ${first}` : '通过刮奖解锁这只猫猫'}</span><span>${item ? `拥有 ×${item.count}` : '未收入图鉴'}</span></div><div class="detail-actions">${item ? `<button class="primary" data-favorite="${id}">${state.favorites.includes(id) ? '从展柜取下' : '放入我的展柜'}</button>` : '<button class="primary" data-go="scratch">去刮一张 →</button>'}<button class="secondary" data-close>收起</button></div>`;
  if (!dialog.open) dialog.showModal();
}

function showRules() {
  $('#dialog-content').innerHTML = `<div class="dialog-top"><h2>小铺的掉落规则</h2><button class="icon-button" data-close title="关闭">×</button></div><p class="rules-copy">三种刮法，共用同一个猫猫奖池。每张票免费，每次独立随机。</p><table class="rules-table"><thead><tr><th>稀有度</th><th>猫猫数量</th><th>总概率</th></tr></thead><tbody>${RARITIES.map(r => `<tr><td>${r.symbol} ${r.name}</td><td>${CATS.filter(c => c.rarity === r.id).length}</td><td>${r.probability}</td></tr>`).join('')}</tbody></table><p class="rules-copy">同一稀有度内，每只猫概率相同。没有保底，不保证在一定次数内获得；传说的 0.5% 约等于平均 200 次出现一次。</p><p class="rules-copy">第一次相遇点亮图鉴，重复相遇增加持有数量。每张票在完全揭晓后自动入册；切换刮法保留这张票里的猫猫。</p><p class="rules-copy">收藏仅保存在当前浏览器，清除网站数据会丢失进度。此版没有账号同步或公共排行榜。图片预览不会解锁收藏。</p><button class="primary" data-close>知道啦，去遇见猫猫</button>`;
  dialog.showModal();
}

function scratchSound(reveal = false) {
  if (!state.sound) return;
  try {
    const Audio = window.AudioContext || window.webkitAudioContext;
    if (!Audio) return;
    soundContext ??= new Audio();
    if (soundContext.state === 'suspended') void soundContext.resume().catch(() => {});
    const now = soundContext.currentTime;
    if (!reveal && now - lastSound < .055) return;
    lastSound = now;
    const gain = soundContext.createGain();
    gain.connect(soundContext.destination);
    if (reveal) {
      const oscillator = soundContext.createOscillator();
      oscillator.type = 'sine';
      oscillator.frequency.setValueAtTime(660, now);
      oscillator.frequency.setValueAtTime(880, now + .09);
      gain.gain.setValueAtTime(.06, now);
      gain.gain.exponentialRampToValueAtTime(.001, now + .35);
      oscillator.connect(gain);
      oscillator.start(); oscillator.stop(now + .36);
      oscillator.onended = () => { oscillator.disconnect(); gain.disconnect(); };
    } else {
      if (!scratchBuffer) {
        scratchBuffer = soundContext.createBuffer(1, soundContext.sampleRate * .065, soundContext.sampleRate);
        const samples = scratchBuffer.getChannelData(0);
        for (let i = 0; i < samples.length; i++) samples[i] = (Math.random() * 2 - 1) * (1 - i / samples.length);
      }
      const source = soundContext.createBufferSource(); source.buffer = scratchBuffer;
      const highpass = soundContext.createBiquadFilter(); highpass.type = 'highpass'; highpass.frequency.value = 1800;
      gain.gain.value = .055;
      source.connect(highpass); highpass.connect(gain); source.start();
      source.onended = () => { source.disconnect(); highpass.disconnect(); gain.disconnect(); };
    }
  } catch { /* Audio is optional; collection never depends on browser audio support. */ }
}

function finishRegion(region) {
  if (conflict || !openRegion(state, region)) return;
  const result = claimTicket(state);
  save();
  if (result) {
    scratchSound(true);
    if (typeof navigator.vibrate === 'function') navigator.vibrate(20);
    render();
    $('#ticket-result').innerHTML = resultMarkup(result.cat, result.isNew);
  } else if (state.ticket.mode === 'career' && region === 'clue') render();
  else {
    const canvas = app.querySelector(`canvas[data-region="${region}"]`);
    canvas?.classList.add('opened');
  }
}

function mountScratch() {
  const abort = new AbortController();
  const observers = [];
  const coverages = new Map();
  const t = state.ticket;
  const signal = abort.signal;
  function updateProgress() {
    const regions = MODES[t.mode].regions;
    const progress = regions.reduce((sum, r) => sum + (t.opened.includes(r) ? 1 : Math.min(1, (coverages.get(r)?.ratio ?? 0) / .65)), 0) / regions.length;
    const bar = $('#scratch-progress');
    if (bar) bar.style.width = `${Math.round(progress * 100)}%`;
  }
  app.querySelectorAll('canvas.scratch:not(.opened)').forEach(canvas => {
    const region = canvas.dataset.region;
    const coverage = new ScratchCoverage();
    coverages.set(region, coverage);
    const ctx = canvas.getContext('2d');
    if (!ctx) { toast('此浏览器无法显示涂层，可以点击「全部刮开」。'); return; }
    const segments = t.strokes[region] ??= [];
    for (const segment of segments) coverage.erase(...segment);
    let pointer = null, previous = null;

    function erase(segment) {
      ctx.save(); ctx.scale(canvas.width, canvas.height);
      ctx.globalCompositeOperation = 'destination-out'; ctx.lineWidth = segment[4] * 2;
      ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      ctx.beginPath(); ctx.moveTo(segment[0], segment[1]); ctx.lineTo(segment[2], segment[3]); ctx.stroke();
      ctx.beginPath(); ctx.arc(segment[2], segment[3], segment[4], 0, Math.PI * 2); ctx.fill();
      ctx.restore();
    }
    function paint() {
      const rect = canvas.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(rect.width * dpr); canvas.height = Math.round(rect.height * dpr);
      const w = canvas.width, h = canvas.height;
      ctx.globalCompositeOperation = 'source-over';
      const gradient = ctx.createLinearGradient(0, 0, w, h);
      gradient.addColorStop(0, '#dadcd5'); gradient.addColorStop(.35, '#c6cbc4'); gradient.addColorStop(.7, '#e7e8e0'); gradient.addColorStop(1, '#bcc4bd');
      ctx.fillStyle = gradient; ctx.fillRect(0, 0, w, h);
      ctx.strokeStyle = '#ffffff35'; ctx.lineWidth = dpr;
      for (let x = -h; x < w; x += 9 * dpr) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x + h, h); ctx.stroke(); }
      const small = region === 'clue';
      ctx.fillStyle = '#657266'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
      if (!small) {
        const scale = Math.min(w, h) / 160;
        ctx.save(); ctx.translate(w / 2, h * .43); ctx.scale(scale, scale);
        ctx.globalAlpha = .65;
        [[-19, -9, 7], [-8, -20, 7], [8, -20, 7], [19, -9, 7], [0, 9, 16]].forEach(([x, y, radius]) => { ctx.beginPath(); ctx.ellipse(x, y, radius, radius * 1.15, 0, 0, Math.PI * 2); ctx.fill(); });
        ctx.restore();
      }
      ctx.font = `600 ${Math.round((small ? 11 : t.mode === 'paws' ? 11 : 16) * dpr)}px system-ui`;
      ctx.fillText(small ? '01  刮开职业线索' : t.mode === 'paws' ? `刮开爪印 ${Number(region) + 1}` : '好 运 藏 在 这 里', w / 2, small ? h / 2 : h * .72);
      if (!small && t.mode !== 'paws') {
        ctx.font = `${Math.round(8 * dpr)}px Georgia`;
        ctx.fillText('A LITTLE SCRATCH, A LITTLE WONDER', w / 2, h * .82);
      }
      for (const segment of segments) erase(segment);
    }
    function point(event) {
      const rect = canvas.getBoundingClientRect();
      return [Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width)), Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height))];
    }
    function move(event) {
      if (pointer !== event.pointerId || conflict || t.opened.includes(region)) return;
      const next = point(event), from = previous ?? next;
      const segment = [...from, ...next, region === 'clue' ? .14 : t.mode === 'paws' ? .105 : .07];
      const before = coverage.count;
      erase(segment); coverage.erase(...segment); previous = next;
      // Only persist strokes that reveal new cells: at most 1,024 segments.
      // Rubbing the same spot indefinitely must never auto-complete a ticket.
      if (coverage.count > before) segments.push(segment);
      scratchSound(); updateProgress();
      if (coverage.ratio >= .65) {
        pointer = null; previous = null;
        finishRegion(region);
        updateProgress();
      }
    }
    canvas.addEventListener('pointerdown', event => {
      if (pointer !== null || !event.isPrimary || event.button !== 0 || conflict) return;
      event.preventDefault(); pointer = event.pointerId; previous = point(event);
      canvas.setPointerCapture(pointer); move(event);
    }, { signal });
    canvas.addEventListener('pointermove', event => {
      const events = typeof event.getCoalescedEvents === 'function' ? event.getCoalescedEvents() : [];
      for (const sample of events.length ? events : [event]) move(sample);
    }, { signal });
    const stop = event => {
      if (pointer !== event.pointerId) return;
      pointer = null; previous = null; save();
    };
    for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) canvas.addEventListener(name, stop, { signal });
    const observer = new ResizeObserver(paint); observer.observe(canvas); observers.push(observer);
    paint();
  });
  updateProgress();
  cleanupScratch = () => { abort.abort(); observers.forEach(observer => observer.disconnect()); };
}

async function exportCard() {
  if (exporting || !state.favorites.length) return;
  exporting = true;
  const button = $('#export-card');
  button.disabled = true; button.textContent = '正在制作展示卡…';
  try {
    const image = new Image();
    image.src = getComputedStyle(app.querySelector('.cat-art')).backgroundImage.slice(5, -2);
    await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = 1080; canvas.height = 1440;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('Canvas unavailable');
    ctx.fillStyle = '#f6f2e9'; ctx.fillRect(0, 0, 1080, 1440);
    ctx.strokeStyle = '#cbb996'; ctx.lineWidth = 3; ctx.strokeRect(42, 42, 996, 1356);
    ctx.textAlign = 'center'; ctx.fillStyle = '#006b60'; ctx.font = '22px Georgia';
    ctx.fillText('CAT & LITTLE WONDERS / VOL. 01', 540, 126);
    ctx.fillStyle = '#463d32'; ctx.font = 'bold 58px "Songti SC", serif'; ctx.fillText('我的猫猫收藏', 540, 218);
    ctx.font = '26px system-ui'; ctx.fillStyle = '#786d5d'; ctx.fillText(`猫猫百业 · 已收集 ${collected()} / 24`, 540, 284);
    const rows = [0, 304, 576, 838, 1096, 1319, 1536];
    for (let i = 0; i < 6; i++) {
      const x = 290 + i % 2 * 500, y = 455 + Math.floor(i / 2) * 280;
      const cat = CATS.find(c => c.id === state.favorites[i]);
      ctx.strokeStyle = '#cbb996'; ctx.lineWidth = 7; ctx.beginPath(); ctx.arc(x, y, 99, 0, Math.PI * 2); ctx.stroke();
      if (cat) {
        const row = Math.floor(cat.index / 4), factor = image.naturalWidth / 1024;
        ctx.save(); ctx.beginPath(); ctx.arc(x, y, 95, 0, Math.PI * 2); ctx.clip();
        ctx.drawImage(image, cat.index % 4 * 256 * factor, rows[row] * factor, 256 * factor, (rows[row + 1] - rows[row]) * factor, x - 95, y - 95, 190, 190); ctx.restore();
        ctx.fillStyle = '#463d32'; ctx.font = 'bold 25px system-ui'; ctx.fillText(`${cat.job} · ${cat.name}`, x, y + 137);
        ctx.fillStyle = '#786d5d'; ctx.font = '19px system-ui'; ctx.fillText(`${RARITIES[cat.rarity].name} / NO. ${String(cat.index + 1).padStart(3, '0')}`, x, y + 170);
      } else {
        ctx.fillStyle = '#ad9c80'; ctx.font = '42px Georgia'; ctx.fillText('?', x, y + 15);
        ctx.font = '22px system-ui'; ctx.fillText('给下一位朋友留个位置', x, y + 137);
      }
    }
    ctx.font = '22px system-ui'; ctx.fillStyle = '#786d5d';
    ctx.fillText(RARITIES.map(r => `${r.name} ${CATS.filter(c => c.rarity === r.id && state.collection[c.id]).length}/${CATS.filter(c => c.rarity === r.id).length}`).join('    '), 540, 1268);
    ctx.font = '24px system-ui'; ctx.fillStyle = '#006b60'; ctx.fillText('刮刮小铺 · 小小一刮，收集生活的可爱。', 540, 1340);
    const blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
    if (!blob) throw new Error('Export failed');
    const url = URL.createObjectURL(blob), link = document.createElement('a');
    link.href = url; link.download = '猫猫百业-我的收藏.png'; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    toast('展示卡已生成，请查看浏览器下载。');
  } catch { toast('展示卡暂时未能生成，请重试。'); }
  finally { exporting = false; if (button.isConnected) { button.disabled = false; button.textContent = '保存展示卡 ↓'; } }
}

function navigate(next) {
  if (!['scratch', 'album', 'showcase'].includes(next)) return;
  save(); dialog.close(); page = next;
  if (location.hash !== `#${next}`) location.hash = next;
  render();
}

document.addEventListener('click', event => {
  const button = event.target.closest('button');
  if (!button) return;
  if (button.hasAttribute('data-close')) { dialog.close(); return; }
  if (conflict) return;
  if (button.dataset.page || button.dataset.go) { navigate(button.dataset.page || button.dataset.go); return; }
  if (button.dataset.detail) { showCat(button.dataset.detail); return; }
  if (button.dataset.mode) { newTicket(state, button.dataset.mode); save(); render(); return; }
  if (button.dataset.filter) { filter = button.dataset.filter; render(); return; }
  if (button.dataset.favorite) {
    const result = toggleFavorite(state, button.dataset.favorite);
    toast({ added: '已放进展柜，去看看吧。', removed: '已从展柜取下，仍保留在图鉴。', full: '展柜已经有六只猫猫啦，先取下一只再放入。', unowned: '先通过刮奖获得这只猫猫。' }[result]);
    save(); render(); showCat(button.dataset.favorite); return;
  }
  switch (button.id) {
    case 'reveal-all':
      for (const region of [...MODES[state.ticket.mode].regions]) finishRegion(region);
      break;
    case 'next-ticket': newTicket(state, state.ticket.mode); save(); render(); break;
    case 'owned-filter': onlyOwned = !onlyOwned; render(); break;
    case 'rules-button': showRules(); break;
    case 'sound-toggle': state.sound = !state.sound; save(); updateHeader(); if (state.sound) scratchSound(true); break;
    case 'theme-toggle': state.theme = state.theme === 'light' ? 'dark' : 'light'; save(); updateHeader(); break;
    case 'export-card': void exportCard(); break;
  }
});

dialog.addEventListener('click', event => { if (event.target === dialog) { const r = dialog.getBoundingClientRect(); if (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom) dialog.close(); } });
window.addEventListener('hashchange', () => { const next = location.hash.slice(1); if (['scratch', 'album', 'showcase'].includes(next) && next !== page) { page = next; dialog.close(); render(); } });
window.addEventListener('pagehide', save);
page = ['scratch', 'album', 'showcase'].includes(location.hash.slice(1)) ? location.hash.slice(1) : 'scratch';
render();
