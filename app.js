// app.js
// 全局入口：初始化数据层 + 系统信息 + 共享状态（store/global.js）
const db = require('./utils/db.js');
const store = require('./store/global.js');

App({
  globalData: {
    store,            // 简单状态 + 事件总线（见 store/global.js）
    systemInfo: null, // 系统信息，页面里可直接读，避免重复调用同步接口
    statusBarHeight: 20,
    windowHeight: 0,
    windowWidth: 0,
    pixelRatio: 2,
    safeAreaBottom: 0,
    settings: null,   // 设置缓存（与 db.getSettings() 保持同步）
  },

  onLaunch() {
    this.initSystemInfo();

    // 首次启动时写入默认数据（默认灵感文件夹、默认设置、默认筛选），并自愈 id 索引
    db.init();

    const settings = db.getSettings();
    this.globalData.settings = settings;
    store.setState({
      ready: true,
      settings,
      wardrobeFilter: db.getWardrobeFilter(),
    });
    store.emit(store.EVENTS.APP_READY, { settings });

    // 设置变化时同步到 globalData，页面用 getApp().globalData.settings 也能拿到最新的值
    store.on(store.EVENTS.SETTINGS_CHANGE, (next) => {
      this.globalData.settings = next;
    }, this);
  },

  onShow() {},

  onError(err) {
    console.error('[app.onError]', err);
  },

  onUnhandledRejection(res) {
    console.error('[app.onUnhandledRejection]', res && res.reason);
  },

  /**
   * 系统信息：优先使用新接口（getWindowInfo / getDeviceInfo），旧基础库回退 getSystemInfoSync
   */
  initSystemInfo() {
    let info = {};
    try {
      if (wx.getWindowInfo) {
        info = Object.assign(
          {},
          wx.getWindowInfo(),
          wx.getDeviceInfo ? wx.getDeviceInfo() : {},
          wx.getAppBaseInfo ? wx.getAppBaseInfo() : {}
        );
      } else {
        info = wx.getSystemInfoSync();
      }
    } catch (err) {
      console.warn('[app] 获取系统信息失败', err);
    }

    const safeArea = info.safeArea;
    this.globalData.systemInfo = info;
    this.globalData.statusBarHeight = info.statusBarHeight || 20;
    this.globalData.windowHeight = info.windowHeight || 0;
    this.globalData.windowWidth = info.windowWidth || 0;
    this.globalData.pixelRatio = info.pixelRatio || 2;
    this.globalData.safeAreaBottom =
      safeArea && info.screenHeight ? Math.max(0, info.screenHeight - safeArea.bottom) : 0;
  },
});
