/**
 * pages/clothing-detail —— 衣物详情
 *
 * 大图 + 属性展示，以及四个动作：编辑、重新抠图、删除、手动加次数。
 * 删除的连带清理（从所有穿搭的 clothingIds / canvasData、灵感的 clothingIds 中移除）在
 * utils/db.js 的 deleteClothing 里统一处理，页面只负责调用和提示。
 *
 * 重新抠图复用 image-editor，入口同添加页：
 *   navigateTo({ url: '...?src=<编码>', events: { done } })，返回的临时文件由本页落盘。
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');
const imageUtil = require('../../utils/image.js');
const dateUtil = require('../../utils/date.js');

Page({
  data: {
    item: null,
    priceText: '未填写',
    lastWornText: '',
    createTimeText: '',
  },

  onLoad(options) {
    this._id = (options && options.id) || '';
    this._loaded = false;
    this.loadItem();

    // 编辑页保存、衣橱页加次数等都会派发这个事件
    store.on(store.EVENTS.CLOTHING_CHANGE, this.loadItem, this);
  },

  onShow() {
    // 从编辑页返回时兜底刷新一次
    if (this._loaded) this.loadItem();
  },

  onUnload() {
    store.offByCtx(this);
  },

  /* ==================== 数据 ==================== */

  loadItem() {
    const item = db.getClothing(this._id);
    if (!item) {
      // 删除流程自己会提示并返回；这里再走一遍会多弹一个「已不存在」并重复返回
      if (this._deleting) return;
      // 可能是在别处被删掉了
      wx.showToast({ title: '这件衣物已不存在', icon: 'none' });
      setTimeout(() => wx.navigateBack(), 600);
      return;
    }

    this._loaded = true;
    this.setData({
      item,
      priceText: item.price ? '¥' + item.price : '未填写',
      lastWornText: item.lastWornDate ? dateUtil.friendlyDate(item.lastWornDate) : '',
      createTimeText: dateUtil.formatDate(new Date(item.createTime)),
    });
  },

  /* ==================== 查看 ==================== */

  onPreviewImage() {
    const item = this.data.item;
    const url = item && (item.coverImage || item.originalImage);
    if (!url) return;
    wx.previewImage({ urls: [url], current: url });
  },

  /* ==================== 加次数 ==================== */

  onWearOnce() {
    if (!this.data.item) return;
    const next = db.increaseWearCount(this._id, 1);
    if (!next) return;
    this.loadItem();
    if (wx.vibrateShort) wx.vibrateShort({ type: 'light', fail() {} });
    wx.showToast({ title: '已记录，共 ' + next.wearCount + ' 次', icon: 'none' });
  },

  /* ==================== 编辑 / 重新抠图 ==================== */

  onEdit() {
    if (!this.data.item) return;
    wx.navigateTo({ url: '/pages/clothing-edit/clothing-edit?id=' + this._id });
  },

  onRecut() {
    const item = this.data.item;
    if (!item) return;
    // 重新抠图用原图（保留原图就是为了这个），没有原图时退回当前展示图
    const src = item.originalImage || item.coverImage;
    if (!src) {
      wx.showToast({ title: '这件衣物还没有图片', icon: 'none' });
      return;
    }

    wx.navigateTo({
      url: '/pages/image-editor/image-editor?src=' + encodeURIComponent(src),
      events: {
        done: (res) => {
          if (res && res.path) this.applyRecut(res.path);
        },
      },
      fail: () => wx.showToast({ title: '打不开图片编辑器', icon: 'none' }),
    });
  },

  applyRecut(tempPath) {
    imageUtil
      .saveImage(tempPath, { prefix: 'cloth-cut' })
      .then((saved) => {
        const oldCover = this.data.item && this.data.item.coverImage;
        const next = db.updateClothing(this._id, { coverImage: saved.path });
        // 旧封面如果没别的地方在用，顺手删掉，别让图片目录越攒越大
        if (oldCover && oldCover !== saved.path && (!next || oldCover !== next.originalImage)) {
          imageUtil.removeFile(oldCover);
        }
        this.loadItem();
        wx.showToast({ title: '已更新抠图', icon: 'success' });
      })
      .catch((err) => {
        console.error('[clothing-detail] 抠图结果保存失败', err);
        wx.showToast({ title: '处理结果保存失败', icon: 'none' });
      });
  },

  /* ==================== 删除 ==================== */

  onDelete() {
    const item = this.data.item;
    if (!item) return;

    wx.showModal({
      title: '删除衣物',
      content: '删除后不可恢复，并会自动从所有穿搭中移除这件衣物。',
      confirmText: '删除',
      confirmColor: '#e0564f',
      success: (res) => {
        if (!res.confirm) return;
        this._deleting = true;
        const result = db.deleteClothing(this._id) || {};
        imageUtil.removeFile(item.originalImage);
        imageUtil.removeFile(item.coverImage);

        const extra = result.affectedOutfits ? '，已从 ' + result.affectedOutfits + ' 套穿搭中移除' : '';
        wx.showToast({ title: '已删除' + extra, icon: 'none' });
        setTimeout(() => wx.navigateBack(), 600);
      },
    });
  },
});
