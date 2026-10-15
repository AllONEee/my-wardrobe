/**
 * pages/outfit-detail —— 穿搭详情
 *
 * 展示：封面（合成图或第一件衣物）、日期、关联衣物、备注。
 * 动作：编辑（回穿搭编辑页）、在试衣间编辑（切到试衣间并把这套搭配装进画布）、删除。
 *
 * 与试衣间的约定：switchTab 不能带参数，所以先把待编辑的 outfitId 放进 store，
 * 试衣间在 onShow 里取走并清空（见 store/global.js 的 state，不落库）。
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');
const dateUtil = require('../../utils/date.js');
const imageUtil = require('../../utils/image.js');

Page({
  data: {
    outfit: null,
    items: [],
    cover: '',
    countText: '',
    dateLabel: '',
    createTimeText: '',
  },

  onLoad(options) {
    this._id = (options && options.id) || '';
    this._loaded = false;
    this.load();

    store.on(store.EVENTS.OUTFIT_CHANGE, this.load, this);
    store.on(store.EVENTS.CLOTHING_CHANGE, this.load, this);
  },

  onShow() {
    // 从编辑页 / 试衣间返回时兜底刷新一次
    if (this._loaded) this.load();
  },

  onUnload() {
    store.offByCtx(this);
  },

  /* ==================== 数据 ==================== */

  load() {
    const outfit = db.getOutfit(this._id);
    if (!outfit) {
      // 删除流程自己会提示并返回，这里再走一遍会多弹一个提示
      if (this._deleting) return;
      wx.showToast({ title: '这套穿搭已不存在', icon: 'none' });
      setTimeout(() => wx.navigateBack(), 600);
      return;
    }

    // 关联衣物可能被删掉（deleteClothing 会同步清理 clothingIds），这里按现存衣物展示
    const items = db.listClothingByIds(outfit.clothingIds);
    const firstImage = items.length
      ? items[0].coverImage || items[0].originalImage || ''
      : '';

    this._loaded = true;
    this.setData({
      outfit,
      items,
      cover: outfit.cover || firstImage,
      countText: items.length ? items.length + ' 件衣物' : '没有关联衣物',
      dateLabel: dateUtil.friendlyDate(outfit.date),
      createTimeText: dateUtil.formatDate(new Date(outfit.createTime)),
    });
  },

  /* ==================== 操作 ==================== */

  onPreviewCover() {
    const url = this.data.cover;
    if (!url) return;
    wx.previewImage({ urls: [url], current: url });
  },

  onOpenClothing(e) {
    const id = (e.detail && e.detail.id) || e.currentTarget.dataset.id;
    if (!id) return;
    wx.navigateTo({ url: '/pages/clothing-detail/clothing-detail?id=' + id });
  },

  onEdit() {
    wx.navigateTo({ url: '/pages/outfit-edit/outfit-edit?id=' + this._id });
  },

  onOpenFitting() {
    store.setState({ pendingFitting: { outfitId: this._id, ts: Date.now() } });
    wx.switchTab({
      url: '/pages/fitting/fitting',
      fail: () => wx.showToast({ title: '打不开试衣间', icon: 'none' }),
    });
  },

  onDelete() {
    const outfit = this.data.outfit;
    if (!outfit) return;

    wx.showModal({
      title: '删除穿搭',
      content: '删除后不可恢复（关联的衣物不会被删除）。',
      confirmText: '删除',
      confirmColor: '#e0564f',
      success: (res) => {
        if (!res.confirm) return;
        this._deleting = true;

        const cover = outfit.cover;
        db.deleteOutfit(this._id);
        // 自定义封面图是我们沙箱里的文件；没有别处引用时一起删掉
        if (cover && !db.isImageInUse(cover)) imageUtil.removeFile(cover);

        wx.showToast({ title: '已删除', icon: 'none' });
        setTimeout(() => wx.navigateBack(), 600);
      },
    });
  },

});
