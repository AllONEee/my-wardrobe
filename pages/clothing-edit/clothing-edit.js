/**
 * pages/clothing-edit —— 添加 / 编辑衣物
 *
 * 流程：wx.chooseMedia 选图 → 选完立刻压缩落盘（得到持久路径）→ 自动跳 image-editor 抠图
 *      → 编辑器通过 eventChannel 回传处理结果 → 表单填写 → 保存进 storage
 *
 * 与 image-editor 的约定（第 5 步的编辑器按这个实现）：
 *   打开：wx.navigateTo({ url: '/pages/image-editor/image-editor?src=<encodeURIComponent 后的路径>', events: { done } })
 *   回传：编辑器里 this.getOpenerEventChannel().emit('done', { path, originalPath })（path 为临时文件路径，由本页负责落盘）
 *
 * 文件清理策略（图片是占空间的大头，必须管好）：
 *   - 本页产生的新文件都记在 _createdFiles 里
 *   - 保存成功：只保留最终引用的两张图，本次产生的其它中间文件删掉；被替换掉的旧图也删掉
 *   - 用户返回 / 取消：_createdFiles 全部删掉，不留垃圾
 */
const db = require('../../utils/db.js');
const dateUtil = require('../../utils/date.js');
const imageUtil = require('../../utils/image.js');

const MAX_TAGS = 10;

Page({
  data: {
    id: '', // 有值 = 编辑模式
    categories: db.CATEGORIES,
    seasonOptions: [],
    seasonCount: 0,
    form: {
      name: '',
      category: db.CATEGORIES[0],
      tags: [],
      seasons: [],
      purchaseDate: '',
      price: '',
      note: '',
    },
    originalImage: '',
    coverImage: '',
    tagInput: '',
    todayKey: dateUtil.today(),
    saving: false,
  },

  onLoad(options) {
    this._createdFiles = []; // 本次新产生、尚未落定的文件
    this._saved = false;

    const id = (options && options.id) || '';
    if (!id) {
      this.setData({ seasonOptions: this.buildSeasonOptions([]) });
      return;
    }

    const item = db.getClothing(id);
    if (!item) {
      wx.showToast({ title: '这件衣物不存在', icon: 'none' });
      setTimeout(() => wx.navigateBack(), 600);
      return;
    }

    wx.setNavigationBarTitle({ title: '编辑衣物' });
    this.setData({
      id,
      form: {
        name: item.name,
        category: item.category,
        tags: (item.tags || []).slice(),
        seasons: (item.seasons || []).slice(),
        purchaseDate: item.purchaseDate || '',
        price: item.price ? String(item.price) : '',
        note: item.note || '',
      },
      seasonOptions: this.buildSeasonOptions(item.seasons),
      originalImage: item.originalImage || '',
      coverImage: item.coverImage || item.originalImage || '',
    });
  },

  onUnload() {
    // 没能保存成功的，把本次产生的图片文件清掉
    if (!this._saved) this._createdFiles.forEach((p) => imageUtil.removeFile(p));
    this._createdFiles = [];
  },

  /* ==================== 图片 ==================== */

  onImageTap() {
    if (!this.data.originalImage) {
      this.pickImage();
      return;
    }
    wx.showActionSheet({
      itemList: ['重新选择图片', '重新抠图'],
      success: (res) => {
        if (res.tapIndex === 0) this.pickImage();
        else this.openEditor(this.data.originalImage);
      },
      fail: () => {},
    });
  },

  pickImage() {
    imageUtil
      .chooseImage({ count: 1 })
      .then((paths) => imageUtil.saveImage(paths[0], { prefix: 'cloth-src' }))
      .then((saved) => {
        this.trackFile(saved.path);
        // 抠图之前先用原图兜底，万一用户在编辑器里直接返回，衣物也有图
        this.setData({ originalImage: saved.path, coverImage: saved.path });
        this.openEditor(saved.path);
      })
      .catch((err) => {
        if (imageUtil.isCancel(err)) return;
        console.error('[clothing-edit] 选图失败', err);
        wx.showToast({ title: '选图失败，请重试', icon: 'none' });
      });
  },

  openEditor(src) {
    wx.navigateTo({
      url: '/pages/image-editor/image-editor?src=' + encodeURIComponent(src),
      events: {
        done: (res) => {
          if (res && res.path) this.applyEdited(res.path);
        },
      },
      fail: () => wx.showToast({ title: '打不开图片编辑器', icon: 'none' }),
    });
  },

  applyEdited(tempPath) {
    imageUtil
      .saveImage(tempPath, { prefix: 'cloth-cut' })
      .then((saved) => {
        this.trackFile(saved.path);
        this.setData({ coverImage: saved.path });
        wx.showToast({ title: '已应用抠图', icon: 'none' });
      })
      .catch((err) => {
        console.error('[clothing-edit] 抠图结果保存失败', err);
        wx.showToast({ title: '处理结果保存失败', icon: 'none' });
      });
  },

  trackFile(path) {
    if (path && this._createdFiles.indexOf(path) < 0) this._createdFiles.push(path);
  },

  /* ==================== 表单 ==================== */

  /** 名称 / 价格 / 备注共用一个 handler，靠 data-field 区分 */
  onFieldInput(e) {
    const field = e.currentTarget.dataset.field;
    if (!field) return;
    const patch = {};
    patch['form.' + field] = e.detail.value;
    this.setData(patch);
  },

  onCategoryTap(e) {
    const value = e.currentTarget.dataset.value;
    if (value === this.data.form.category) return;
    this.setData({ 'form.category': value });
  },

  onSeasonTap(e) {
    const value = e.currentTarget.dataset.value;
    const seasons = this.data.form.seasons.slice();
    const index = seasons.indexOf(value);
    if (index >= 0) seasons.splice(index, 1);
    else seasons.push(value);
    // 按固定顺序排列，保存后各处展示都稳定
    seasons.sort((a, b) => db.SEASONS.indexOf(a) - db.SEASONS.indexOf(b));
    this.setData({
      'form.seasons': seasons,
      seasonOptions: this.buildSeasonOptions(seasons),
      seasonCount: seasons.length,
    });
  },

  buildSeasonOptions(selected) {
    const list = selected || [];
    return db.SEASONS.map((value) => ({ value, active: list.indexOf(value) >= 0 }));
  },

  onTagInput(e) {
    this.setData({ tagInput: e.detail.value });
  },

  onAddTag() {
    this.addTag(this.data.tagInput);
  },

  onTagConfirm(e) {
    this.addTag(e.detail.value);
  },

  addTag(raw) {
    const value = String(raw || '').trim();
    if (!value) return;

    const tags = this.data.form.tags.slice();
    if (tags.indexOf(value) >= 0) {
      this.setData({ tagInput: '' });
      return;
    }
    if (tags.length >= MAX_TAGS) {
      wx.showToast({ title: '标签最多 ' + MAX_TAGS + ' 个', icon: 'none' });
      return;
    }
    tags.push(value);
    this.setData({ 'form.tags': tags, tagInput: '' });
  },

  onRemoveTag(e) {
    const index = Number(e.currentTarget.dataset.index);
    const tags = this.data.form.tags.slice();
    if (index < 0 || index >= tags.length) return;
    tags.splice(index, 1);
    this.setData({ 'form.tags': tags });
  },

  onDateChange(e) {
    this.setData({ 'form.purchaseDate': e.detail.value });
  },

  onClearDate() {
    this.setData({ 'form.purchaseDate': '' });
  },

  /* ==================== 保存 ==================== */

  onSave() {
    if (this.data.saving) return;

    const form = this.data.form;
    const name = String(form.name || '').trim();
    if (!name) {
      wx.showToast({ title: '给这件衣物起个名字吧', icon: 'none' });
      return;
    }

    this.setData({ saving: true });

    const oldItem = this.data.id ? db.getClothing(this.data.id) : null;
    const coverImage = this.data.coverImage || this.data.originalImage || '';
    const saved = db.saveClothing({
      id: this.data.id || undefined,
      name,
      category: form.category,
      tags: form.tags,
      seasons: form.seasons,
      purchaseDate: form.purchaseDate,
      price: form.price,
      note: form.note,
      originalImage: this.data.originalImage,
      coverImage,
      // 编辑时保留原有统计
      wearCount: oldItem ? oldItem.wearCount : 0,
      lastWornDate: oldItem ? oldItem.lastWornDate : '',
    });

    this._saved = true;
    this.cleanupFiles(saved, oldItem);

    wx.showToast({ title: this.data.id ? '已保存' : '已添加', icon: 'success' });
    setTimeout(() => wx.navigateBack(), 500);
  },

  /**
   * 保存成功后的文件清理：
   *  - 本次产生但最终没用上的中间文件删掉
   *  - 编辑模式下被替换掉的旧图删掉
   */
  cleanupFiles(saved, oldItem) {
    const keep = [saved.originalImage, saved.coverImage];
    this._createdFiles.forEach((path) => {
      if (keep.indexOf(path) < 0) imageUtil.removeFile(path);
    });
    this._createdFiles = [];

    if (!oldItem) return;
    if (oldItem.originalImage && keep.indexOf(oldItem.originalImage) < 0) {
      imageUtil.removeFile(oldItem.originalImage);
    }
    if (oldItem.coverImage && keep.indexOf(oldItem.coverImage) < 0) {
      imageUtil.removeFile(oldItem.coverImage);
    }
  },
});
