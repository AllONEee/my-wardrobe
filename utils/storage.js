/**
 * utils/storage.js —— 本地存储底座
 *
 * 职责：
 *  - 统一 key 前缀，业务层不写裸字符串
 *  - 同步读写（wx.setStorageSync / wx.getStorageSync），配合 globalData + 简单事件做状态管理
 *  - 只存 JSON 可序列化的数据；图片本身存文件系统，这里只存路径（见 utils/image.js）
 *
 * 注意：小程序单 key 上限 1MB，总量上限 10MB，衣物列表这类结构化数据足够用；
 *      但千万不要把 base64 图片塞进 storage。
 */

const PREFIX = 'wardrobe_';

/** 所有 storage key 的集中定义 */
const KEYS = {
  SCHEMA_VERSION: 'schema_version',
  ID_SEQ: 'id_seq', // 自增序号，用于生成全局唯一 id
  ID_INDEX: 'id_index', // { [id]: 'clothing' | 'outfit' | 'inspiration' | 'folder' }
  CLOTHING: 'clothing_list',
  OUTFIT: 'outfit_list',
  INSPIRATION: 'inspiration_list',
  FOLDER: 'folder_list',
  SETTINGS: 'settings',
  WARDROBE_FILTER: 'wardrobe_filter',
  CUTOUT_CONFIG: 'cutout_config', // 云端抠图接口配置（可在不发版的情况下替换）
  WEATHER_CONFIG: 'weather_config', // 天气接口配置（Key / 上次用的城市）
  WEATHER_LOG: 'weather_log', // { 'YYYY-MM-DD': { city, cityId, temp, text, ... } } 日记里的天气记录
};

/** 数据结构版本号，后续字段变更时在这里做迁移 */
const SCHEMA_VERSION = 1;

function realKey(key) {
  return PREFIX + key;
}

/**
 * 读取，失败或不存在时返回 default_value
 */
function get(key, defaultValue) {
  try {
    const value = wx.getStorageSync(realKey(key));
    if (value === '' || value === undefined || value === null) return defaultValue;
    return value;
  } catch (err) {
    console.warn('[storage] 读取失败：', key, err);
    return defaultValue;
  }
}

/**
 * 写入，返回是否成功
 */
function set(key, value) {
  try {
    wx.setStorageSync(realKey(key), value);
    return true;
  } catch (err) {
    console.error('[storage] 写入失败：', key, err);
    wx.showToast({ title: '本地存储写入失败', icon: 'none' });
    return false;
  }
}

function remove(key) {
  try {
    wx.removeStorageSync(realKey(key));
    return true;
  } catch (err) {
    console.warn('[storage] 删除失败：', key, err);
    return false;
  }
}

/**
 * 只清理本小程序自己写入的 key（带前缀的），不影响其它模块可能写入的缓存
 */
function clearAll() {
  try {
    const info = wx.getStorageInfoSync();
    (info.keys || []).forEach((k) => {
      if (k.indexOf(PREFIX) === 0) wx.removeStorageSync(k);
    });
    return true;
  } catch (err) {
    console.error('[storage] 清理失败', err);
    return false;
  }
}

/**
 * 版本迁移入口：app.js 启动时调用一次
 * 返回 true 表示本次做了一次迁移（首次安装也算）
 */
function initSchema() {
  const current = get(KEYS.SCHEMA_VERSION, 0);
  if (current === SCHEMA_VERSION) return false;

  // v0 -> v1：首次安装，无需迁移；后续版本变更在这里按 current 逐级升级
  set(KEYS.SCHEMA_VERSION, SCHEMA_VERSION);
  return true;
}

/**
 * 容量信息，设置页展示用
 */
function getInfo() {
  try {
    const info = wx.getStorageInfoSync();
    return {
      keys: info.keys || [],
      currentSize: info.currentSize || 0, // KB
      limitSize: info.limitSize || 0, // KB
    };
  } catch (err) {
    return { keys: [], currentSize: 0, limitSize: 0 };
  }
}

module.exports = {
  PREFIX,
  KEYS,
  SCHEMA_VERSION,
  get,
  set,
  remove,
  clearAll,
  initSchema,
  getInfo,
};
