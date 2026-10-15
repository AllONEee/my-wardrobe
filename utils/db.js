/**
 * utils/db.js —— 数据层（衣物 / 穿搭 / 灵感 / 文件夹 / 设置）
 *
 * 设计：
 *  - 数据以 JSON 形式存在 wx.setStorageSync（见 utils/storage.js），图片只存路径（见 utils/image.js）
 *  - id 全局唯一：前缀区分类型（c=衣物 o=穿搭 i=灵感 f=文件夹），并维护 id -> type 索引，便于统一按 id 反查
 *  - 任何写操作都会 emit 对应事件（store/global.js），页面订阅后自动刷新
 *  - 所有写操作都是「读全量 -> 改 -> 整体写回」，数据量级（几百件衣物）下完全够用
 */

const storage = require('./storage.js');
const dateUtil = require('./date.js');
const store = require('../store/global.js');

const KEYS = storage.KEYS;

/** 固定分类 */
const CATEGORIES = ['上衣', '裤子', '裙子', '鞋', '配饰', '套装'];
/** 固定季节 */
const SEASONS = ['春', '夏', '秋', '冬'];
/** 筛选项里的「全部」 */
const ALL = '全部';

/** 默认灵感文件夹（不可删除） */
const DEFAULT_FOLDER_ID = 'f1';
/** 试衣间里的虚拟「搭配」文件夹：不落库，直接对应全部穿搭 */
const OUTFIT_FOLDER = { id: 'outfit', name: '搭配', type: 'outfit', virtual: true };

const TYPE_PREFIX = { clothing: 'c', outfit: 'o', inspiration: 'i', folder: 'f' };
const PREFIX_TYPE = { c: 'clothing', o: 'outfit', i: 'inspiration', f: 'folder' };
const TYPE_LIST_KEY = {
  clothing: KEYS.CLOTHING,
  outfit: KEYS.OUTFIT,
  inspiration: KEYS.INSPIRATION,
  folder: KEYS.FOLDER,
};
const TYPE_EVENT = {
  clothing: store.EVENTS.CLOTHING_CHANGE,
  outfit: store.EVENTS.OUTFIT_CHANGE,
  inspiration: store.EVENTS.INSPIRATION_CHANGE,
};

const DEFAULT_SETTINGS = {
  showLastWorn: true, // 衣橱卡片是否显示最近穿着日期
};

const DEFAULT_WARDROBE_FILTER = {
  category: ALL,
  season: ALL,
  keyword: '',
};

/* ==================== 通用工具 ==================== */

function readList(key) {
  const list = storage.get(key, []);
  return Array.isArray(list) ? list : [];
}

function writeList(key, list) {
  return storage.set(key, list);
}

function nextId(type) {
  const seq = storage.get(KEYS.ID_SEQ, 0) + 1;
  storage.set(KEYS.ID_SEQ, seq);
  return TYPE_PREFIX[type] + seq.toString(36);
}

function readIndex() {
  const index = storage.get(KEYS.ID_INDEX, {});
  return index && typeof index === 'object' ? index : {};
}

function indexAdd(id, type) {
  const index = readIndex();
  index[id] = type;
  storage.set(KEYS.ID_INDEX, index);
}

function indexRemove(id) {
  const index = readIndex();
  if (index[id]) {
    delete index[id];
    storage.set(KEYS.ID_INDEX, index);
  }
}

function emitChange(type, payload) {
  const evt = TYPE_EVENT[type];
  if (evt) store.emit(evt, Object.assign({ type }, payload || {}));
}

function findById(key, id) {
  return readList(key).find((item) => item.id === id) || null;
}

/**
 * 统一按 id 反查任意实体：{ type, item } 或 null
 * 优先查 id 索引，索引缺失时按 id 前缀兜底
 */
function getById(id) {
  if (!id) return null;
  const type = readIndex()[id] || PREFIX_TYPE[String(id)[0]];
  if (!type || !TYPE_LIST_KEY[type]) return null;
  const item = findById(TYPE_LIST_KEY[type], id);
  return item ? { type, item } : null;
}

/* ==================== 衣物 ==================== */

function normalizeClothing(input) {
  const src = input || {};
  const id = src.id || nextId('clothing');
  const rawPrice = src.price;
  const price = rawPrice === '' || rawPrice === null || rawPrice === undefined ? 0 : Number(rawPrice) || 0;
  return {
    id,
    name: String(src.name || '').trim() || '未命名衣物',
    coverImage: src.coverImage || '', // 展示用图（通常为抠图后的图）
    originalImage: src.originalImage || '', // 原图，保留用于「重新抠图」
    category: CATEGORIES.indexOf(src.category) >= 0 ? src.category : CATEGORIES[0],
    tags: Array.isArray(src.tags) ? src.tags.filter(Boolean) : [],
    seasons: Array.isArray(src.seasons) ? src.seasons.filter((s) => SEASONS.indexOf(s) >= 0) : [],
    purchaseDate: src.purchaseDate || '',
    price,
    note: src.note || '',
    wearCount: Number(src.wearCount) || 0,
    lastWornDate: src.lastWornDate || '',
    createTime: src.createTime || Date.now(),
  };
}

/**
 * 列表查询
 * @param {{category?: string, season?: string, keyword?: string}} filter 「全部」或空表示不过滤
 */
function listClothing(filter) {
  const f = filter || {};
  const category = f.category || ALL;
  const season = f.season || ALL;
  const keyword = String(f.keyword || '').trim().toLowerCase();

  let list = readList(KEYS.CLOTHING);
  if (category && category !== ALL) {
    list = list.filter((item) => item.category === category);
  }
  if (season && season !== ALL) {
    list = list.filter((item) => (item.seasons || []).indexOf(season) >= 0);
  }
  if (keyword) {
    // 按名称和备注搜索
    list = list.filter((item) => {
      const name = String(item.name || '').toLowerCase();
      const note = String(item.note || '').toLowerCase();
      return name.indexOf(keyword) >= 0 || note.indexOf(keyword) >= 0;
    });
  }
  return list.sort((a, b) => b.createTime - a.createTime);
}

function getClothing(id) {
  return findById(KEYS.CLOTHING, id);
}

/** 按 id 数组取衣物（保持传入顺序，自动跳过已删除的） */
function listClothingByIds(ids) {
  const map = {};
  readList(KEYS.CLOTHING).forEach((item) => {
    map[item.id] = item;
  });
  return (ids || []).map((id) => map[id]).filter(Boolean);
}

function addClothing(data) {
  const item = normalizeClothing(
    Object.assign({}, data, { id: nextId('clothing'), createTime: Date.now() })
  );
  const list = readList(KEYS.CLOTHING);
  list.push(item);
  writeList(KEYS.CLOTHING, list);
  indexAdd(item.id, 'clothing');
  emitChange('clothing', { action: 'add', id: item.id });
  return item;
}

function updateClothing(id, patch) {
  const list = readList(KEYS.CLOTHING);
  const idx = list.findIndex((item) => item.id === id);
  if (idx < 0) return null;
  const next = normalizeClothing(
    Object.assign({}, list[idx], patch, { id, createTime: list[idx].createTime })
  );
  list[idx] = next;
  writeList(KEYS.CLOTHING, list);
  emitChange('clothing', { action: 'update', id });
  return next;
}

/** 新增或更新统一入口：带 id 且已存在则更新，否则新增 */
function saveClothing(data) {
  if (data && data.id && getClothing(data.id)) return updateClothing(data.id, data);
  return addClothing(data);
}

/**
 * 删除衣物，并同步清理：
 *  - 所有穿搭 clothingIds / canvasData
 *  - 所有灵感 clothingIds
 */
function deleteClothing(id) {
  const list = readList(KEYS.CLOTHING).filter((item) => item.id !== id);
  writeList(KEYS.CLOTHING, list);
  indexRemove(id);

  let affectedOutfits = 0;
  const outfits = readList(KEYS.OUTFIT).map((outfit) => {
    if ((outfit.clothingIds || []).indexOf(id) < 0) return outfit;
    affectedOutfits++;
    return Object.assign({}, outfit, {
      clothingIds: (outfit.clothingIds || []).filter((cid) => cid !== id),
      canvasData: (outfit.canvasData || []).filter((c) => c.clothingId !== id),
    });
  });
  if (affectedOutfits) {
    writeList(KEYS.OUTFIT, outfits);
    emitChange('outfit', { action: 'update', reason: 'clothing-deleted', id });
  }

  let affectedInspirations = 0;
  const inspirations = readList(KEYS.INSPIRATION).map((item) => {
    if ((item.clothingIds || []).indexOf(id) < 0) return item;
    affectedInspirations++;
    return Object.assign({}, item, {
      clothingIds: (item.clothingIds || []).filter((cid) => cid !== id),
    });
  });
  if (affectedInspirations) {
    writeList(KEYS.INSPIRATION, inspirations);
    emitChange('inspiration', { action: 'update', reason: 'clothing-deleted', id });
  }

  emitChange('clothing', { action: 'delete', id });
  return { affectedOutfits, affectedInspirations };
}

/**
 * 加/减穿着次数，加次数时顺带更新最近穿着日期
 * @param {string} id
 * @param {number} step 默认 +1，传负数可减
 */
function increaseWearCount(id, step) {
  const item = getClothing(id);
  if (!item) return null;
  const n = typeof step === 'number' ? step : 1;
  const wearCount = Math.max(0, (Number(item.wearCount) || 0) + n);
  return updateClothing(id, {
    wearCount,
    lastWornDate: n > 0 ? dateUtil.today() : item.lastWornDate,
  });
}

/* ==================== 穿搭 ==================== */

function normalizeCanvasData(list) {
  if (!Array.isArray(list)) return [];
  return list
    .filter((item) => item && item.clothingId)
    .map((item, i) => ({
      clothingId: item.clothingId,
      x: Number(item.x) || 0,
      y: Number(item.y) || 0,
      scale: item.scale ? Number(item.scale) : 1,
      rotation: Number(item.rotation) || 0,
      zIndex: typeof item.zIndex === 'number' ? item.zIndex : i + 1,
    }));
}

function normalizeOutfit(input) {
  const src = input || {};
  return {
    id: src.id || nextId('outfit'),
    clothingIds: Array.isArray(src.clothingIds) ? src.clothingIds.filter(Boolean) : [],
    canvasData: normalizeCanvasData(src.canvasData),
    cover: src.cover || '', // 保存搭配时用 canvas 合成的封面图
    note: src.note || '',
    date: src.date || dateUtil.today(),
    createTime: src.createTime || Date.now(),
  };
}

/**
 * @param {{date?: string}} filter 传 date 则只返回当天的穿搭
 */
function listOutfits(filter) {
  const f = filter || {};
  let list = readList(KEYS.OUTFIT);
  if (f.date) list = list.filter((item) => item.date === f.date);
  return list.sort((a, b) => b.createTime - a.createTime);
}

function getOutfit(id) {
  return findById(KEYS.OUTFIT, id);
}

/** 有穿搭记录的日期（'YYYY-MM-DD'），用于日记页日历打点 */
function listOutfitDates() {
  const set = {};
  readList(KEYS.OUTFIT).forEach((item) => {
    if (item.date) set[item.date] = true;
  });
  return Object.keys(set);
}

/** date -> 当天穿搭数量，日历角标用 */
function countOutfitsByDate() {
  const map = {};
  readList(KEYS.OUTFIT).forEach((item) => {
    if (!item.date) return;
    map[item.date] = (map[item.date] || 0) + 1;
  });
  return map;
}

function addOutfit(data) {
  const outfit = normalizeOutfit(
    Object.assign({}, data, { id: nextId('outfit'), createTime: Date.now() })
  );
  const list = readList(KEYS.OUTFIT);
  list.push(outfit);
  writeList(KEYS.OUTFIT, list);
  indexAdd(outfit.id, 'outfit');
  emitChange('outfit', { action: 'add', id: outfit.id });
  return outfit;
}

function updateOutfit(id, patch) {
  const list = readList(KEYS.OUTFIT);
  const idx = list.findIndex((item) => item.id === id);
  if (idx < 0) return null;
  const next = normalizeOutfit(
    Object.assign({}, list[idx], patch, { id, createTime: list[idx].createTime })
  );
  list[idx] = next;
  writeList(KEYS.OUTFIT, list);
  emitChange('outfit', { action: 'update', id });
  return next;
}

function saveOutfit(data) {
  if (data && data.id && getOutfit(data.id)) return updateOutfit(data.id, data);
  return addOutfit(data);
}

/**
 * 复制一套穿搭（试衣间的「复制搭配」）
 * @param {string} id
 * @param {{date?: string, note?: string}} overrides
 */
function duplicateOutfit(id, overrides) {
  const outfit = getOutfit(id);
  if (!outfit) return null;
  const patch = Object.assign({}, outfit, overrides || {});
  delete patch.id;
  delete patch.createTime;
  return addOutfit(patch);
}

function deleteOutfit(id) {
  const list = readList(KEYS.OUTFIT).filter((item) => item.id !== id);
  writeList(KEYS.OUTFIT, list);
  indexRemove(id);
  emitChange('outfit', { action: 'delete', id });
  return true;
}

/* ==================== 灵感 ==================== */

function normalizeInspiration(input) {
  const src = input || {};
  return {
    id: src.id || nextId('inspiration'),
    folderId: src.folderId || DEFAULT_FOLDER_ID,
    images: Array.isArray(src.images) ? src.images.filter(Boolean) : [],
    clothingIds: Array.isArray(src.clothingIds) ? src.clothingIds.filter(Boolean) : [],
    title: src.title || '',
    note: src.note || '',
    createTime: src.createTime || Date.now(),
  };
}

/**
 * @param {string} folderId 传空表示全部
 */
function listInspirations(folderId) {
  let list = readList(KEYS.INSPIRATION);
  if (folderId) list = list.filter((item) => item.folderId === folderId);
  return list.sort((a, b) => b.createTime - a.createTime);
}

function getInspiration(id) {
  return findById(KEYS.INSPIRATION, id);
}

function addInspiration(data) {
  const item = normalizeInspiration(
    Object.assign({}, data, { id: nextId('inspiration'), createTime: Date.now() })
  );
  const list = readList(KEYS.INSPIRATION);
  list.push(item);
  writeList(KEYS.INSPIRATION, list);
  indexAdd(item.id, 'inspiration');
  emitChange('inspiration', { action: 'add', id: item.id });
  return item;
}

function updateInspiration(id, patch) {
  const list = readList(KEYS.INSPIRATION);
  const idx = list.findIndex((item) => item.id === id);
  if (idx < 0) return null;
  const next = normalizeInspiration(
    Object.assign({}, list[idx], patch, { id, createTime: list[idx].createTime })
  );
  list[idx] = next;
  writeList(KEYS.INSPIRATION, list);
  emitChange('inspiration', { action: 'update', id });
  return next;
}

function saveInspiration(data) {
  if (data && data.id && getInspiration(data.id)) return updateInspiration(data.id, data);
  return addInspiration(data);
}

function deleteInspiration(id) {
  const list = readList(KEYS.INSPIRATION).filter((item) => item.id !== id);
  writeList(KEYS.INSPIRATION, list);
  indexRemove(id);
  emitChange('inspiration', { action: 'delete', id });
  return true;
}

/* ==================== 灵感文件夹 ==================== */

function buildDefaultFolder() {
  return { id: DEFAULT_FOLDER_ID, name: '灵感', type: 'inspiration', createTime: Date.now() };
}

function listFolders() {
  return readList(KEYS.FOLDER);
}

function getFolder(id) {
  return findById(KEYS.FOLDER, id);
}

/**
 * 试衣间顶部 tab 用的文件夹列表：虚拟「搭配」文件夹 + 灵感文件夹
 */
function listFittingFolders() {
  return [OUTFIT_FOLDER].concat(listFolders());
}

function addFolder(name, type) {
  const folder = {
    id: nextId('folder'),
    name: String(name || '').trim() || '新文件夹',
    type: type || 'inspiration',
    createTime: Date.now(),
  };
  const list = readList(KEYS.FOLDER);
  list.push(folder);
  writeList(KEYS.FOLDER, list);
  indexAdd(folder.id, 'folder');
  return folder;
}

function renameFolder(id, name) {
  const list = readList(KEYS.FOLDER);
  const idx = list.findIndex((item) => item.id === id);
  if (idx < 0) return null;
  list[idx] = Object.assign({}, list[idx], { name: String(name || '').trim() || list[idx].name });
  writeList(KEYS.FOLDER, list);
  return list[idx];
}

/** 删除文件夹：其中的灵感移到默认文件夹，默认文件夹不可删 */
function deleteFolder(id) {
  if (id === DEFAULT_FOLDER_ID) return false;
  writeList(
    KEYS.FOLDER,
    readList(KEYS.FOLDER).filter((item) => item.id !== id)
  );
  indexRemove(id);

  const inspirations = readList(KEYS.INSPIRATION).map((item) =>
    item.folderId === id ? Object.assign({}, item, { folderId: DEFAULT_FOLDER_ID }) : item
  );
  writeList(KEYS.INSPIRATION, inspirations);
  emitChange('inspiration', { action: 'update', reason: 'folder-deleted', id });
  return true;
}

/* ==================== 设置 / 衣橱筛选 ==================== */

function getSettings() {
  return Object.assign({}, DEFAULT_SETTINGS, storage.get(KEYS.SETTINGS, {}));
}

function saveSettings(patch) {
  const next = Object.assign(getSettings(), patch || {});
  storage.set(KEYS.SETTINGS, next);
  store.setState({ settings: next });
  store.emit(store.EVENTS.SETTINGS_CHANGE, next);
  return next;
}

function getWardrobeFilter() {
  return Object.assign({}, DEFAULT_WARDROBE_FILTER, storage.get(KEYS.WARDROBE_FILTER, {}));
}

function saveWardrobeFilter(patch) {
  const next = Object.assign(getWardrobeFilter(), patch || {});
  storage.set(KEYS.WARDROBE_FILTER, next);
  store.setState({ wardrobeFilter: next });
  store.emit(store.EVENTS.WARDROBE_FILTER_CHANGE, next);
  return next;
}

/* ==================== 初始化 / 导出 / 清空 ==================== */

/**
 * 这张图片是否还被引用（衣物封面 / 原图、穿搭封面、灵感图）。
 * 删除文件前先问一句：衣物封面和穿搭自定义封面可能指向同一个路径，误删会让别处变成空白。
 */
function isImageInUse(path) {
  if (!path) return false;
  const usedByClothing = readList(KEYS.CLOTHING).some(
    (item) => item.coverImage === path || item.originalImage === path
  );
  if (usedByClothing) return true;
  const usedByOutfit = readList(KEYS.OUTFIT).some((item) => item.cover === path);
  if (usedByOutfit) return true;
  return readList(KEYS.INSPIRATION).some((item) => (item.images || []).indexOf(path) >= 0);
}

/** 按现有数据重建 id 索引，并从已有 id 里恢复自增序号，避免 id 冲突 */
function rebuildIndex() {
  const index = {};
  let maxSeq = storage.get(KEYS.ID_SEQ, 0) || 0;
  Object.keys(TYPE_LIST_KEY).forEach((type) => {
    readList(TYPE_LIST_KEY[type]).forEach((item) => {
      if (!item || !item.id) return;
      index[item.id] = type;
      const seq = parseInt(String(item.id).slice(1), 36);
      if (!isNaN(seq) && seq > maxSeq) maxSeq = seq;
    });
  });
  storage.set(KEYS.ID_INDEX, index);
  storage.set(KEYS.ID_SEQ, maxSeq);
}

/**
 * app.js onLaunch 调用
 */
function init() {
  storage.initSchema();

  if (!readList(KEYS.FOLDER).length) {
    writeList(KEYS.FOLDER, [buildDefaultFolder()]);
  }
  if (!storage.get(KEYS.SETTINGS, null)) {
    storage.set(KEYS.SETTINGS, DEFAULT_SETTINGS);
  }
  if (!storage.get(KEYS.WARDROBE_FILTER, null)) {
    storage.set(KEYS.WARDROBE_FILTER, DEFAULT_WARDROBE_FILTER);
  }

  rebuildIndex();
}

/**
 * 导出全部数据（设置页「导出 JSON」用；图片是文件路径，导出的是路径清单）
 */
function exportData() {
  return {
    app: 'wardrobe-miniprogram',
    version: storage.SCHEMA_VERSION,
    exportTime: new Date().toISOString(),
    settings: getSettings(),
    folders: listFolders(),
    clothing: readList(KEYS.CLOTHING),
    outfits: readList(KEYS.OUTFIT),
    inspirations: readList(KEYS.INSPIRATION),
  };
}

/**
 * 清空业务数据（图片文件由 utils/image.js 的 clearImages 单独清理），保留自增序号
 */
function clearAll() {
  writeList(KEYS.CLOTHING, []);
  writeList(KEYS.OUTFIT, []);
  writeList(KEYS.INSPIRATION, []);
  writeList(KEYS.FOLDER, [buildDefaultFolder()]);
  storage.set(KEYS.ID_INDEX, {});
  storage.set(KEYS.SETTINGS, DEFAULT_SETTINGS);
  storage.set(KEYS.WARDROBE_FILTER, DEFAULT_WARDROBE_FILTER);

  store.setState({ settings: DEFAULT_SETTINGS, wardrobeFilter: DEFAULT_WARDROBE_FILTER });
  emitChange('clothing', { action: 'clear' });
  emitChange('outfit', { action: 'clear' });
  emitChange('inspiration', { action: 'clear' });
  store.emit(store.EVENTS.SETTINGS_CHANGE, DEFAULT_SETTINGS);
  store.emit(store.EVENTS.WARDROBE_FILTER_CHANGE, DEFAULT_WARDROBE_FILTER);
}

module.exports = {
  CATEGORIES,
  SEASONS,
  ALL,
  DEFAULT_FOLDER_ID,
  OUTFIT_FOLDER,
  DEFAULT_SETTINGS,
  DEFAULT_WARDROBE_FILTER,

  init,
  getById,
  exportData,
  clearAll,
  isImageInUse,

  listClothing,
  listClothingByIds,
  getClothing,
  addClothing,
  updateClothing,
  saveClothing,
  deleteClothing,
  increaseWearCount,

  listOutfits,
  getOutfit,
  listOutfitDates,
  countOutfitsByDate,
  addOutfit,
  updateOutfit,
  saveOutfit,
  duplicateOutfit,
  deleteOutfit,

  listInspirations,
  getInspiration,
  addInspiration,
  updateInspiration,
  saveInspiration,
  deleteInspiration,

  listFolders,
  listFittingFolders,
  getFolder,
  addFolder,
  renameFolder,
  deleteFolder,

  getSettings,
  saveSettings,
  getWardrobeFilter,
  saveWardrobeFilter,
};
