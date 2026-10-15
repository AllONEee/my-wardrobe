/**
 * pages/diary —— 穿搭日记
 *
 * 结构：上面是月历（有记录的日期打点），下面是选中那天的穿搭列表。
 * 一天可以有多套穿搭，每套都能单独设封面（用关联衣物的图，或从相册选一张）。
 *
 * 说明：
 *  - 月历网格由 utils/date.js 的 monthGrid 生成（固定 6 行 7 列，切换月份时高度不跳）
 *  - 切月份时选中日期跟着落到「该月 1 号 / 今天」，避免日历和下面的列表对不上
 *  - 自定义封面图是我们自己沙箱里的文件，换封面 / 删穿搭时只在「没有别处引用」时才删掉
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');
const dateUtil = require('../../utils/date.js');
const imageUtil = require('../../utils/image.js');

const MAX_THUMBS = 6;

Page({
  data: {
    weekLabels: dateUtil.WEEK_LABELS,
    monthKey: '',
    monthTitle: '',
    cells: [],
    selectedDate: '',
    selectedLabel: '',
    outfits: [],
    totalOutfits: 0,
    totalDays: 0,
  },

  onLoad() {
    const today = dateUtil.today();
    this._today = today;
    this.setData({
      selectedDate: today,
      monthKey: dateUtil.monthKeyOf(today),
    });

    // 任何地方的穿搭 / 衣物变化都会派发事件，这里跟着刷新
    store.on(store.EVENTS.OUTFIT_CHANGE, this.refresh, this);
    store.on(store.EVENTS.CLOTHING_CHANGE, this.refresh, this);
  },

  onShow() {
    // 从编辑页 / 详情页返回时兜底刷新一次
    this.refresh();
  },

  onUnload() {
    store.offByCtx(this);
  },

  /* ==================== 数据 ==================== */

  refresh() {
    const counts = db.countOutfitsByDate();
    const dates = db.listOutfitDates();
    const selectedDate = this.data.selectedDate || this._today;

    const cells = dateUtil.monthGrid(this.data.monthKey).map((cell) =>
      Object.assign({}, cell, {
        count: counts[cell.date] || 0,
        selected: cell.date === selectedDate,
      })
    );

    this.setData({
      cells,
      monthTitle: dateUtil.formatMonthTitle(this.data.monthKey),
      selectedLabel: this.labelOf(selectedDate),
      outfits: this.buildOutfits(selectedDate),
      totalOutfits: db.listOutfits().length,
      totalDays: dates.length,
    });
  },

  /** 当天穿搭 + 展示用字段（封面、衣物缩略图） */
  buildOutfits(date) {
    const outfits = db.listOutfits({ date });
    if (!outfits.length) return [];

    // 衣物一次性读出来做成 map，别在循环里反复读 storage
    const map = {};
    db.listClothing().forEach((item) => {
      map[item.id] = item;
    });

    return outfits.map((outfit) => {
      const items = (outfit.clothingIds || []).map((id) => map[id]).filter(Boolean);
      const thumbs = items.slice(0, MAX_THUMBS).map((item) => ({
        id: item.id,
        image: item.coverImage || item.originalImage || '',
      }));
      const firstImage = thumbs.length ? thumbs[0].image : '';
      return {
        id: outfit.id,
        cover: outfit.cover || firstImage,
        hasCover: !!outfit.cover,
        note: outfit.note || '',
        thumbs,
        more: Math.max(0, items.length - thumbs.length),
        countText: items.length + ' 件衣物',
      };
    });
  },

  labelOf(date) {
    const weekday = '周' + dateUtil.WEEK_LABELS[dateUtil.parseDate(date).getDay()];
    return dateUtil.friendlyDate(date) + ' · ' + weekday;
  },

  /* ==================== 日历 ==================== */

  onDayTap(e) {
    const date = e.currentTarget.dataset.date;
    if (!date) return;
    const monthKey = dateUtil.monthKeyOf(date);
    this.setData({
      selectedDate: date,
      // 点到上/下个月的补位格子时，顺手把月历也切过去
      monthKey: monthKey === this.data.monthKey ? this.data.monthKey : monthKey,
    });
    this.refresh();
  },

  onPrevMonth() {
    this.switchMonth(-1);
  },

  onNextMonth() {
    this.switchMonth(1);
  },

  switchMonth(delta) {
    // addMonths 收的是 'YYYY-MM-DD'（内部按本地时区解析），所以补上 1 号再算
    const monthKey = dateUtil.monthKeyOf(dateUtil.addMonths(this.data.monthKey + '-01', delta));
    const todayKey = dateUtil.monthKeyOf(this._today);
    this.setData({
      monthKey,
      selectedDate: monthKey === todayKey ? this._today : monthKey + '-01',
    });
    this.refresh();
  },

  onToday() {
    this.setData({
      monthKey: dateUtil.monthKeyOf(this._today),
      selectedDate: this._today,
    });
    this.refresh();
  },

  /* ==================== 跳转 ==================== */

  onAdd() {
    wx.navigateTo({
      url: '/pages/outfit-edit/outfit-edit?date=' + this.data.selectedDate,
    });
  },

  onOpenOutfit(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    wx.navigateTo({ url: '/pages/outfit-detail/outfit-detail?id=' + id });
  },

  /* ==================== 设置封面 ==================== */

  onSetCover(e) {
    const id = e.currentTarget.dataset.id;
    const outfit = db.getOutfit(id);
    if (!outfit) return;

    const items = db.listClothingByIds(outfit.clothingIds).filter(
      (item) => item.coverImage || item.originalImage
    );
    const actions = [];
    if (items.length) actions.push('用关联衣物的图片');
    actions.push('从相册选一张');
    if (outfit.cover) actions.push('恢复默认封面');

    wx.showActionSheet({
      itemList: actions,
      success: (res) => {
        const label = actions[res.tapIndex];
        if (label === '用关联衣物的图片') this.pickCoverFromClothing(id, items);
        else if (label === '从相册选一张') this.pickCoverFromAlbum(id);
        else this.applyCover(id, '');
      },
      fail: () => {},
    });
  },

  pickCoverFromClothing(id, items) {
    wx.showActionSheet({
      itemList: items.map((item) => item.name).slice(0, 6),
      success: (res) => {
        const item = items[res.tapIndex];
        if (item) this.applyCover(id, item.coverImage || item.originalImage);
      },
      fail: () => {},
    });
  },

  pickCoverFromAlbum(id) {
    imageUtil
      .chooseImage({ count: 1 })
      .then((paths) => imageUtil.saveImage(paths[0], { prefix: 'outfit-cover' }))
      .then((saved) => this.applyCover(id, saved.path))
      .catch((err) => {
        if (imageUtil.isCancel(err)) return;
        console.error('[diary] 选图失败', err);
        wx.showToast({ title: '选图失败，请重试', icon: 'none' });
      });
  },

  applyCover(id, cover) {
    const outfit = db.getOutfit(id);
    if (!outfit) return;
    db.updateOutfit(id, { cover });

    // 换掉的旧封面如果只属于这套穿搭，顺手删掉，别让图片目录越攒越大
    const old = outfit.cover;
    if (old && old !== cover && !db.isImageInUse(old)) imageUtil.removeFile(old);

    wx.showToast({ title: cover ? '封面已更新' : '已恢复默认封面', icon: 'none' });
  },
});
