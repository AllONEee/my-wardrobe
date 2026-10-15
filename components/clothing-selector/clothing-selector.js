/**
 * components/clothing-selector —— 选衣弹层（穿搭编辑 / 试衣间添加衣物 / 灵感关联衣物共用）
 *
 * 交互约定：
 *  - 弹层内部的勾选是「草稿」：点「确定」才通过 bind:confirm 回传，点遮罩 / 关闭不影响外部数据
 *  - 每次 show 由 false 变 true 时，用传入的 selected 重建草稿；打开期间父组件再改 selected 不会打断用户
 *  - 打开期间订阅衣橱数据事件，别处删了衣物这里会立刻同步
 *
 * 事件：
 *  - bind:confirm  detail = { ids, items }（items 为按勾选顺序排列的衣物对象，已过滤掉被删掉的）
 *  - bind:close    detail = {}
 * 父组件记得在这两个事件里把 show 置回 false。
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');

const ALL = db.ALL;

Component({
  properties: {
    show: {
      type: Boolean,
      value: false,
    },
    // 打开时预选中的衣物 id
    selected: {
      type: Array,
      value: [],
    },
    title: {
      type: String,
      value: '选择衣物',
    },
    confirmText: {
      type: String,
      value: '确定',
    },
    // 最多可选数量，0 表示不限
    max: {
      type: Number,
      value: 0,
    },
  },

  data: {
    categories: [ALL].concat(db.CATEGORIES),
    category: ALL,
    keyword: '',
    list: [], // 每项是衣物对象 + picked（勾选态，只用于渲染）
    count: 0,
    total: 0,
  },

  observers: {
    show(show) {
      if (show) this.openSheet();
      else this.closeSheet();
    },
  },

  lifetimes: {
    detached() {
      this.clearSearchTimer();
      store.offByCtx(this);
    },
  },

  methods: {
    /* ==================== 开关 ==================== */

    openSheet() {
      this._draft = (this.data.selected || []).slice();
      this._list = [];
      this.setData({
        category: ALL,
        keyword: '',
        count: this._draft.length,
      });
      this.reload();
      store.on(store.EVENTS.CLOTHING_CHANGE, this.reload, this);
    },

    closeSheet() {
      this.clearSearchTimer();
      store.off(store.EVENTS.CLOTHING_CHANGE, this.reload, this);
    },

    /* ==================== 列表 ==================== */

    reload() {
      if (!this.data.show) return;
      const list = db.listClothing({
        category: this.data.category,
        keyword: this.data.keyword,
      });
      const draft = this._draft || [];
      this._list = list;
      this.setData({
        list: list.map((item) =>
          Object.assign({}, item, { picked: draft.indexOf(item.id) >= 0 })
        ),
        total: db.listClothing().length,
      });
    },

    onCategoryTap(e) {
      const value = e.currentTarget.dataset.value;
      if (!value || value === this.data.category) return;
      this.setData({ category: value });
      this.reload();
    },

    /** 输入防抖，避免每敲一个字都全量过滤一遍 */
    onKeywordInput(e) {
      const keyword = e.detail.value;
      this.setData({ keyword });
      this.clearSearchTimer();
      this._searchTimer = setTimeout(() => {
        this._searchTimer = null;
        this.reload();
      }, 220);
    },

    clearSearchTimer() {
      if (this._searchTimer) {
        clearTimeout(this._searchTimer);
        this._searchTimer = null;
      }
    },

    /* ==================== 勾选 ==================== */

    /** 卡片图片区和空白区都用来切换勾选（组件里点哪儿都是选它） */
    onToggle(e) {
      const id = e.detail && e.detail.id;
      if (!id) return;

      const draft = this._draft || [];
      const index = draft.indexOf(id);
      if (index >= 0) {
        draft.splice(index, 1);
      } else {
        if (this.data.max && draft.length >= this.data.max) {
          wx.showToast({ title: '最多选 ' + this.data.max + ' 件', icon: 'none' });
          return;
        }
        draft.push(id);
      }

      const i = this.data.list.findIndex((item) => item.id === id);
      const patch = { count: draft.length };
      if (i >= 0) patch['list[' + i + '].picked'] = index < 0;
      this.setData(patch);

      if (wx.vibrateShort) wx.vibrateShort({ type: 'light', fail() {} });
    },

    onClearPicked() {
      if (!this.data.count) return;
      this._draft = [];
      const patch = { count: 0 };
      this.data.list.forEach((item, i) => {
        patch['list[' + i + '].picked'] = false;
      });
      this.setData(patch);
    },

    onConfirm() {
      if (!this.data.count) {
        wx.showToast({ title: '还没有选中衣物', icon: 'none' });
        return;
      }
      const ids = (this._draft || []).slice();
      // 按勾选顺序回传，找不到的（刚被删掉）直接跳过
      const items = ids
        .map((id) => this._list.find((item) => item.id === id) || db.getClothing(id))
        .filter(Boolean);
      this.triggerEvent('confirm', { ids, items });
    },

    onClose() {
      this.triggerEvent('close');
    },
  },
});
