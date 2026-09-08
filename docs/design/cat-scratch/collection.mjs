export const RARITIES = [
  { id: 0, name: '普通', english: 'COMMON', weight: 7000, probability: '70%', symbol: '○' },
  { id: 1, name: '稀有', english: 'RARE', weight: 2400, probability: '24%', symbol: '◇' },
  { id: 2, name: '史诗', english: 'EPIC', weight: 550, probability: '5.5%', symbol: '✦' },
  { id: 3, name: '传说', english: 'LEGENDARY', weight: 50, probability: '0.5%', symbol: '✧' },
];

const characters = [
  ['面包师', '小麦', '把早安揉进面团，把温柔烤成面包。', '清晨五点，整条街就闻到了香气。'],
  ['邮递员', '信仔', '每一封信，都值得翻山越岭。', '包里装着远方，也装着想念。'],
  ['园丁', '苔苔', '种下的每一颗种子，都有自己的春天。', '爪子上总沾着一点泥土。'],
  ['学生', '豆包', '今天的难题，是午睡还是先写作业。', '书包里藏着一条小鱼干。'],
  ['咖啡师', '摩卡', '一杯温热的拿铁，刚好装下整个下午。', '最拿手的是猫爪拉花。'],
  ['农夫', '南瓜', '认真种菜，也认真在草帽下打盹。', '口袋里的种子比零食还多。'],
  ['护士', '棉棉', '贴上小小创可贴，再送你一个拥抱。', '随身小包里总有治愈的东西。'],
  ['花艺师', '山茶', '不擅长说的话，就交给花束吧。', '能把普通的一天扎成一束花。'],
  ['渔夫', '阿汐', '等鱼上钩，也等落日把海面染红。', '最有耐心，也最容易嘴馋。'],
  ['木匠', '木木', '用一双巧爪，给小动物们造个家。', '沙沙声里，一块木头有了新模样。'],
  ['画家', '点点', '胡须沾着颜料，眼睛盛着彩虹。', '把看见的世界变成七种颜色。'],
  ['图书管理员', '书卷', '每一本合上的书，都藏着一个宇宙。', '喜欢安静，也喜欢冒险故事。'],
  ['侦探', '福喵', '失踪的小鱼干，逃不过这双眼睛。', '一副放大镜，一百个为什么。'],
  ['魔术师', '墨墨', '帽子里没有兔子，只有惊喜和猫毛。', '眨一下眼，纸牌就不见了。'],
  ['船长', '罗盘', '风往哪里吹，故事就从哪里开始。', '望远镜的另一端，是新的海岸。'],
  ['摇滚乐手', '闪电', '世界太安静？那就拨响第一根弦。', '一到舞台上，就忘记了害羞。'],
  ['宇航员', '团子', '在失重的宇宙里，追一颗漂浮的鱼干。', '头盔外的星星格外清楚。'],
  ['摄影师', '快门', '把稍纵即逝的快乐，留在一张照片里。', '常说的一句话是：看这里！'],
  ['甜点师', '莓莓', '在蛋糕尖上，放一颗刚刚好的草莓。', '每次出场，都带着甜甜的香气。'],
  ['炼金术师', '琥珀', '今天的新配方：三滴月光，一点勇气。', '玻璃瓶里，冒着不认识的星光。'],
  ['星际领航员', '北辰', '即使迷失在银河，也认得回家的方向。', '摊开的地图上，没有一条普通的路。'],
  ['御厨', '金栗', '山珍海味之外，最想做一碗家常面。', '金线围裙下，是最挑剔的味蕾。'],
  ['梦境画家', '眠眠', '等你睡着，就来给你的梦添一抹颜色。', '画笔只在月亮升起以后发光。'],
  ['星愿收藏家', '星弥', '把每个小小的愿望收好，等它长成星星。', '斗篷里的每一颗星，都是谁的心愿。'],
];

export const CATS = characters.map(([job, name, story, clue], index) => ({
  id: `cat-${String(index + 1).padStart(2, '0')}`, index, job, name, story, clue,
  rarity: index < 12 ? 0 : index < 19 ? 1 : index < 23 ? 2 : 3,
}));
export const MODES = {
  photo: { name: '猫猫拍立得', subtitle: '整面自由刮', regions: ['portrait'] },
  paws: { name: '爪印刮刮卡', subtitle: '四格慢慢揭晓', regions: ['0', '1', '2', '3'] },
  career: { name: '神秘职业证', subtitle: '先线索，后身份', regions: ['clue', 'portrait'] },
};

export function randomUnit() {
  const bytes = new Uint32Array(1);
  globalThis.crypto.getRandomValues(bytes);
  return bytes[0] / 4294967296;
}

export function drawCat(random = randomUnit) {
  const roll = random() * 10000;
  let boundary = 0;
  const rarity = RARITIES.find(r => (boundary += r.weight) > roll) ?? RARITIES.at(-1);
  const pool = CATS.filter(cat => cat.rarity === rarity.id);
  return pool[Math.floor(random() * pool.length)];
}

export function createState() {
  return { version: 1, collection: {}, favorites: [], total: 0, serial: 0, ticket: null, sound: false, theme: 'light' };
}

export function newTicket(state, mode = 'photo', random = randomUnit) {
  if (!MODES[mode]) throw new Error('Unknown scratch mode');
  if (state.ticket && !state.ticket.claimed) {
    // Changing the reveal method never rerolls a hidden reward.
    if (state.ticket.mode !== mode) {
      state.ticket.mode = mode;
      state.ticket.opened = [];
      state.ticket.strokes = {};
    }
    return state.ticket;
  }
  state.ticket = { id: ++state.serial, catId: drawCat(random).id, mode, claimed: false, opened: [], strokes: {} };
  return state.ticket;
}

export function openRegion(state, region) {
  const ticket = state.ticket;
  if (!ticket || ticket.claimed || !MODES[ticket.mode].regions.includes(region)) return false;
  if (ticket.mode === 'career' && region === 'portrait' && !ticket.opened.includes('clue')) return false;
  if (!ticket.opened.includes(region)) ticket.opened.push(region);
  delete ticket.strokes[region];
  return true;
}

export function claimTicket(state, time = new Date().toISOString()) {
  const ticket = state.ticket;
  if (!ticket || ticket.claimed || !MODES[ticket.mode].regions.every(r => ticket.opened.includes(r))) return null;
  ticket.claimed = true;
  const previous = state.collection[ticket.catId];
  state.collection[ticket.catId] = { count: (previous?.count ?? 0) + 1, first: previous?.first ?? time };
  state.total++;
  return { cat: CATS.find(c => c.id === ticket.catId), isNew: !previous };
}

export function toggleFavorite(state, id) {
  if (!state.collection[id]) return 'unowned';
  if (state.favorites.includes(id)) {
    state.favorites = state.favorites.filter(item => item !== id);
    return 'removed';
  }
  if (state.favorites.length >= 6) return 'full';
  state.favorites.push(id);
  return 'added';
}

export function restoreState(raw) {
  if (raw === null) return createState();
  const state = JSON.parse(raw);
  const validId = id => CATS.some(cat => cat.id === id);
  const integer = value => Number.isSafeInteger(value) && value >= 0;
  const validDate = value => typeof value === 'string' && Number.isFinite(Date.parse(value));
  const validStrokes = strokes => strokes && typeof strokes === 'object' && !Array.isArray(strokes)
    && Object.values(strokes).every(list => Array.isArray(list) && list.length <= 4000 && list.every(segment =>
      Array.isArray(segment) && segment.length === 5 && segment.every(n => Number.isFinite(n) && n >= 0 && n <= 1)));
  if (!state || state.version !== 1 || !state.collection || Array.isArray(state.collection)
    || !Array.isArray(state.favorites) || state.favorites.length > 6
    || new Set(state.favorites).size !== state.favorites.length
    || !integer(state.total) || !integer(state.serial) || typeof state.sound !== 'boolean'
    || !['light', 'dark'].includes(state.theme)
    || !Object.entries(state.collection).every(([id, item]) => validId(id) && item && integer(item.count) && item.count > 0 && validDate(item.first))
    || !state.favorites.every(id => validId(id) && state.collection[id])
    || state.total !== Object.values(state.collection).reduce((sum, item) => sum + item.count, 0)) throw new Error('Invalid collection save');
  const t = state.ticket;
  if (t !== null && (!t || !validId(t.catId) || !MODES[t.mode] || typeof t.claimed !== 'boolean'
    || !integer(t.id) || t.id !== state.serial || !Array.isArray(t.opened)
    || new Set(t.opened).size !== t.opened.length || !t.opened.every(r => MODES[t.mode].regions.includes(r))
    || !validStrokes(t.strokes) || !Object.keys(t.strokes).every(r => MODES[t.mode].regions.includes(r))
    || (t.mode === 'career' && t.opened.includes('portrait') && !t.opened.includes('clue'))
    || (t.claimed && (!state.collection[t.catId] || !MODES[t.mode].regions.every(r => t.opened.includes(r)))))) throw new Error('Invalid ticket save');
  return state;
}

// A normalized geometric mask makes coverage independent of pointer frequency,
// device pixel ratio and resize. Repeated strokes over one spot do not progress.
export class ScratchCoverage {
  constructor() { this.cells = new Uint8Array(32 * 32); this.count = 0; }
  erase(x0, y0, x1, y1, radius) {
    const dx = x1 - x0, dy = y1 - y0, length = dx * dx + dy * dy;
    for (let row = 0; row < 32; row++) for (let col = 0; col < 32; col++) {
      const index = row * 32 + col;
      if (this.cells[index]) continue;
      const x = (col + .5) / 32, y = (row + .5) / 32;
      const t = length ? Math.max(0, Math.min(1, ((x - x0) * dx + (y - y0) * dy) / length)) : 0;
      if ((x - x0 - t * dx) ** 2 + (y - y0 - t * dy) ** 2 <= radius ** 2) {
        this.cells[index] = 1;
        this.count++;
      }
    }
  }
  get ratio() { return this.count / this.cells.length; }
}
