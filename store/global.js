/**
 * store/global.js —— 极简全局状态 + 事件总线
 *
 * 用法：
 *   const store = require('../../store/global.js');
 *   onLoad() { store.on(store.EVENTS.CLOTHING_CHANGE, this.loadData, this); },
 *   onUnload() { store.off(store.EVENTS.CLOTHING_CHANGE, this.loadData, this); },
 *   // 数据层写完后会自动 emit，页面监听到就刷新
 *
 * 约定：
 *  - 只放“跨页面共享”的少量状态（设置、筛选条件、就绪标记），业务数据一律走 utils/db.js。
 *  - 不做深层响应式，页面需要响应变化请用事件订阅，而不是直接读 state。
 */

const EVENTS = {
  APP_READY: 'app:ready',
  CLOTHING_CHANGE: 'clothing:change', // { action: 'add' | 'update' | 'delete', id }
  OUTFIT_CHANGE: 'outfit:change',
  INSPIRATION_CHANGE: 'inspiration:change',
  SETTINGS_CHANGE: 'settings:change', // 参数为最新的 settings 对象
  WARDROBE_FILTER_CHANGE: 'wardrobe:filter', // 参数为最新的筛选条件
  WEATHER_CHANGE: 'weather:change', // 日记里的天气记录 / 接口配置变了
};

/** 共享状态（由 app.js / db.js 写入） */
const state = {
  ready: false,
  settings: null, // { showLastWorn: true }
  wardrobeFilter: null, // { category, season, keyword }
};

/** evt -> [{ fn, ctx }] */
const listeners = Object.create(null);

function on(evt, fn, ctx) {
  if (typeof fn !== 'function') return;
  if (!listeners[evt]) listeners[evt] = [];
  listeners[evt].push({ fn, ctx: ctx || null });
}

/**
 * off(evt)                 移除该事件的所有监听
 * off(evt, fn)             移除该事件下该函数的所有监听
 * off(evt, fn, ctx)        精确移除
 */
function off(evt, fn, ctx) {
  const arr = listeners[evt];
  if (!arr) return;
  if (!fn) {
    delete listeners[evt];
    return;
  }
  listeners[evt] = arr.filter((item) => {
    if (ctx !== undefined && item.fn === fn && item.ctx === (ctx || null)) return false;
    if (ctx === undefined && item.fn === fn) return false;
    return true;
  });
}

/** 页面 onUnload 里一次性注销本页面注册的所有监听，避免内存泄漏 */
function offByCtx(ctx) {
  if (!ctx) return;
  Object.keys(listeners).forEach((evt) => {
    listeners[evt] = listeners[evt].filter((item) => item.ctx !== ctx);
  });
}

function once(evt, fn, ctx) {
  const wrapper = function (payload) {
    off(evt, wrapper, ctx);
    fn.call(ctx || null, payload);
  };
  on(evt, wrapper, ctx);
}

function emit(evt, payload) {
  const arr = listeners[evt];
  if (!arr || !arr.length) return;
  arr.slice().forEach((item) => {
    try {
      item.fn.call(item.ctx, payload);
    } catch (err) {
      console.error('[store] 事件回调异常：', evt, err);
    }
  });
}

function setState(patch) {
  Object.assign(state, patch || {});
  return state;
}

function getState() {
  return state;
}

module.exports = {
  EVENTS,
  state,
  on,
  off,
  offByCtx,
  once,
  emit,
  setState,
  getState,
};
