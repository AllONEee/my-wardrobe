/**
 * pages/wardrobe —— 衣橱
 *
 * 功能：分类 / 季节筛选、按名称和备注搜索、3 列网格、
 *      点图片进详情、点卡片空白区 wearCount++、悬浮 + 添加衣物。
 * 筛选状态（分类/季节/关键词）存在 storage 里，下次进入自动恢复。
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');

const ALL = db.ALL;

Page({
  data: {
    categories: [ALL].concat(db.CATEGORIES),
    seasons: [ALL].concat(db.SEASONS),
    filter: Object.assign({}, db.DEFAULT_WARDROBE_FILTER),
    keyword: '', // 输入框的即时值（防抖后才写进 filter）
    showLastWorn: true,
    list: [],
    total: 0,
    hasFilter: false,
    emptyType: 'none', // none | empty（衣橱为空） | no-result（筛选无结果）
  },

  onLoad() {
    const filter = db.getWardrobeFilter();
    this.setData({
      filter,
      keyword: filter.keyword || '',
      showLastWorn: db.getSettings().showLastWorn !== false,
    });
    this.loadList();

    // 数据层写入后会自动派发事件，这里订阅后自动刷新
    store.on(store.EVENTS.CLOTHING_CHANGE, this.loadList, this);
    store.on(store.EVENTS.SETTINGS_CHANGE, this.onSettingsChange, this);
  },

  onUnload() {
    this.clearSearchTimer();
    store.offByCtx(this);
  },

  /* ==================== 数据 ==================== */

  loadList() {
    // 点卡片加次数时已经就地更新过那一张卡片，跳过这次整表刷新
    if (this._skipNextChange) {
      this._skipNextChange = false;
      return;
    }

    const filter = this.data.filter;
    const list = db.listClothing(filter);
    const total = db.listClothing().length; // 全部衣物数，用来区分“衣橱为空”和“筛选无结果”

    this.setData({
      list,
      total,
      hasFilter: this.hasFilter(filter),
      emptyType: list.length ? 'none' : total === 0 ? 'empty' : 'no-result',
    });
  },

  hasFilter(filter) {
    const f = filter || {};
    return f.category !== ALL || f.season !== ALL || !!String(f.keyword || '').trim();
  },

  onSettingsChange(settings) {
    this.setData({ showLastWorn: (settings || {}).showLastWorn !== false });
  },

  /* ==================== 筛选 / 搜索 ==================== */

  applyFilter(patch) {
    // 筛选状态落 storage
    const filter = db.saveWardrobeFilter(patch);
    this.setData({ filter });
    this.loadList();
  },

  onCategoryTap(e) {
    const value = e.currentTarget.dataset.value;
    if (value === this.data.filter.category) return;
    this.applyFilter({ category: value });
  },

  onSeasonTap(e) {
    const value = e.currentTarget.dataset.value;
    if (value === this.data.filter.season) return;
    this.applyFilter({ season: value });
  },

  /** 输入防抖：连续打字时只在停下来之后查一次 */
  onKeywordInput(e) {
    const keyword = e.detail.value;
    this.setData({ keyword });
    this.clearSearchTimer();
    this._searchTimer = setTimeout(() => {
      this._searchTimer = null;
      if ((this.data.filter.keyword || '') === keyword) return;
      this.applyFilter({ keyword });
    }, 260);
  },

  /** 键盘回车：立即搜索，不等防抖 */
  onKeywordConfirm(e) {
    this.clearSearchTimer();
    const keyword = e.detail.value;
    if ((this.data.filter.keyword || '') !== keyword) this.applyFilter({ keyword });
  },

  onClearKeyword() {
    this.clearSearchTimer();
    this.setData({ keyword: '' });
    this.applyFilter({ keyword: '' });
  },

  onResetFilter() {
    this.clearSearchTimer();
    this.setData({ keyword: '' });
    this.applyFilter({ category: ALL, season: ALL, keyword: '' });
  },

  clearSearchTimer() {
    if (this._searchTimer) {
      clearTimeout(this._searchTimer);
      this._searchTimer = null;
    }
  },

  /* ==================== 卡片交互 ==================== */

  /** 点图片 -> 衣物详情 */
  onOpenDetail(e) {
    const id = e.detail && e.detail.id;
    if (!id) return;
    wx.navigateTo({ url: '/pages/clothing-detail/clothing-detail?id=' + id });
  },

  /** 点卡片空白区 -> 穿着次数 +1（图片区域已被组件 catchtap 拦住，不会走到这里） */
  onWearOnce(e) {
    const id = e.detail && e.detail.id;
    if (!id) return;

    this._skipNextChange = true;
    const next = db.increaseWearCount(id, 1);
    if (!next) {
      // 衣物已被删除等异常情况，让事件监听照常刷新
      this._skipNextChange = false;
      this.loadList();
      return;
    }

    const index = this.data.list.findIndex((item) => item.id === id);
    if (index >= 0) {
      const patch = {};
      patch['list[' + index + '].wearCount'] = next.wearCount;
      patch['list[' + index + '].lastWornDate'] = next.lastWornDate;
      this.setData(patch);
    }

    // 轻震动作为“已记录”的反馈，比弹 toast 更安静
    if (wx.vibrateShort) {
      wx.vibrateShort({ type: 'light', fail() {} });
    }
  },

  /* ==================== 跳转 ==================== */

  onAdd() {
    wx.navigateTo({ url: '/pages/clothing-edit/clothing-edit' });
  },

  onEmptyAction() {
    if (this.data.emptyType === 'empty') this.onAdd();
    else this.onResetFilter();
  },
});
