/**
 * components/empty-state —— 空状态
 * 只需传文案，需要按钮时传 actionText 并监听 bind:action。
 */
Component({
  properties: {
    text: {
      type: String,
      value: '暂无内容',
    },
    desc: {
      type: String,
      value: '',
    },
    actionText: {
      type: String,
      value: '',
    },
  },

  methods: {
    onAction() {
      this.triggerEvent('action');
    },
  },
});
