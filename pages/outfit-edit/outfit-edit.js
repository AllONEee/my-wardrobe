/**
 * pages/outfit-edit —— 新增 / 编辑一套穿搭
 *
 * 入口：
 *  - /pages/outfit-edit/outfit-edit?date=YYYY-MM-DD  从日记页新增（不传则是今天）
 *  - /pages/outfit-edit/outfit-edit?id=o1            从穿搭详情 / 试衣间进入编辑
 *
 * 选衣走 clothing-selector 弹层（多选，弹层回传的是「勾选后的完整列表」，直接替换即可）。
 * 季节是可选的（春/夏/秋/冬，可多选；都不选表示四季都能穿），用来给试衣间的「我的搭配」分类。
 * 保存时：
 *  - 新增：canvasData 为空，等用户去试衣间摆位置、生成封面
 *  - 编辑：保留原有的 canvasData（只过滤掉本次被移除的衣物）与封面
 */
const db = require('../../utils/db.js');
const dateUtil = require('../../utils/date.js');

Page({
  data: {
    id: '',
    date: '',
    note: '',
    seasons: [], // 已选季节（空 = 没标，四季都能穿）
    seasonOptions: [],
    seasonCount: 0,
    picked: [], // 已选衣物 id（同时作为选衣弹层的初始选中项）
    items: [], // 已选衣物（展示用）
    countText: '',
    showSelector: false,
  },

  onLoad(options) {
    const id = (options && options.id) || '';
    const today = dateUtil.today();
    this.setData({
      id,
      date: (options && options.date) || today,
      seasonOptions: this.buildSeasonOptions([]),
    });

    if (!id) {
      this.refreshItems();
      return;
    }

    const outfit = db.getOutfit(id);
    if (!outfit) {
      wx.showToast({ title: '这套穿搭已不存在', icon: 'none' });
      setTimeout(() => wx.navigateBack(), 600);
      return;
    }

    wx.setNavigationBarTitle({ title: '编辑穿搭' });
    this.setData({
      date: outfit.date || today,
      note: outfit.note || '',
      seasons: (outfit.seasons || []).slice(),
      seasonOptions: this.buildSeasonOptions(outfit.seasons),
      seasonCount: (outfit.seasons || []).length,
      picked: (outfit.clothingIds || []).slice(),
    });
    this.refreshItems();
  },

  /* ==================== 季节 ==================== */

  /** 季节多选（不选表示四季都能穿），顺序固定，保存后各处展示都稳定 */
  onSeasonTap(e) {
    const value = e.currentTarget.dataset.value;
    const seasons = this.data.seasons.slice();
    const index = seasons.indexOf(value);
    if (index >= 0) seasons.splice(index, 1);
    else seasons.push(value);
    seasons.sort((a, b) => db.SEASONS.indexOf(a) - db.SEASONS.indexOf(b));
    this.setData({
      seasons,
      seasonOptions: this.buildSeasonOptions(seasons),
      seasonCount: seasons.length,
    });
  },

  buildSeasonOptions(selected) {
    const list = selected || [];
    return db.SEASONS.map((value) => ({ value, active: list.indexOf(value) >= 0 }));
  },

  /* ==================== 关联衣物 ==================== */

  refreshItems() {
    const items = db.listClothingByIds(this.data.picked).map((item) => ({
      id: item.id,
      name: item.name,
      image: item.coverImage || item.originalImage || '',
    }));
    this.setData({
      items,
      countText: items.length ? items.length + ' 件' : '',
    });
  },

  onAddClothing() {
    this.setData({ showSelector: true });
  },

  onSelectorClose() {
    this.setData({ showSelector: false });
  },

  onSelectorConfirm(e) {
    const ids = (e.detail && e.detail.ids) || [];
    this.setData({ showSelector: false, picked: ids });
    this.refreshItems();
  },

  onRemoveItem(e) {
    const id = e.currentTarget.dataset.id;
    const picked = this.data.picked.filter((item) => item !== id);
    this.setData({ picked });
    this.refreshItems();
  },

  /* ==================== 表单 ==================== */

  onDateChange(e) {
    this.setData({ date: e.detail.value });
  },

  onNoteInput(e) {
    this.setData({ note: e.detail.value });
  },

  /* ==================== 保存 ==================== */

  onSave() {
    const picked = this.data.picked;
    if (!picked.length) {
      wx.showToast({ title: '先选几件衣物吧', icon: 'none' });
      return;
    }

    const old = this.data.id ? db.getOutfit(this.data.id) : null;
    // 编辑时保留画布摆位；被移除的衣物对应的摆位一并丢掉，避免留下看不见的空位
    const canvasData = old
      ? (old.canvasData || []).filter((item) => picked.indexOf(item.clothingId) >= 0)
      : [];

    db.saveOutfit({
      id: this.data.id || undefined,
      clothingIds: picked,
      canvasData,
      cover: old ? old.cover : '',
      seasons: this.data.seasons,
      note: this.data.note,
      date: this.data.date,
      createTime: old ? old.createTime : undefined,
    });

    wx.showToast({ title: this.data.id ? '已保存' : '已记录', icon: 'success' });
    setTimeout(() => wx.navigateBack(), 500);
  },
});
