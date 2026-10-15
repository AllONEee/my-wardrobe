/**
 * components/clothing-card —— 衣物卡片（衣橱网格 / 穿搭详情 / 选衣弹层共用）
 *
 * 交互约定（组件只负责“报告发生了什么”，业务逻辑由页面处理）：
 *  - 点图片区域  -> triggerEvent('tapimage')  —— 图片上用 catchtap 拦住，避免冒泡到卡片
 *  - 点其余空白区 -> triggerEvent('tapcard')   —— 衣橱页据此 wearCount++
 *
 * 传入的 item 就是 db 里的 ClothingItem 原样数据，不要在页面里另造结构。
 */
const dateUtil = require('../../utils/date.js');

Component({
  properties: {
    item: {
      type: Object,
      value: null,
    },
    // 是否显示最近穿着日期（对应设置页的显示设置）
    showLastWorn: {
      type: Boolean,
      value: true,
    },
    // 是否显示穿着次数角标
    showWearCount: {
      type: Boolean,
      value: true,
    },
  },

  data: {
    image: '', // coverImage 优先，没有再退回原图
    lastWornText: '',
  },

  observers: {
    'item, showLastWorn': function (item, showLastWorn) {
      const next = item || {};
      let lastWornText = '';
      if (showLastWorn && next.lastWornDate) {
        // 今天 / 昨天 / M月D日，避免卡片上出现一长串日期
        lastWornText = dateUtil.friendlyDate(next.lastWornDate);
      }
      this.setData({
        image: next.coverImage || next.originalImage || '',
        lastWornText,
      });
    },
  },

  methods: {
    onImageTap() {
      const item = this.data.item;
      if (!item || !item.id) return;
      this.triggerEvent('tapimage', { id: item.id, item });
    },

    onCardTap() {
      const item = this.data.item;
      if (!item || !item.id) return;
      this.triggerEvent('tapcard', { id: item.id, item });
    },
  },
});
