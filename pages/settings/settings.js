/**
 * pages/settings —— 设置
 *
 * 三块内容：
 *  - 显示设置：衣橱卡片是否显示最近穿着日期（写进 storage，衣橱页订阅事件后即时生效）
 *  - 数据：导出 JSON（写成文件 / 复制到剪贴板）、清空数据、查看存储与图片占用
 *  - 关于：版本、数据说明、云端抠图接口配置
 *
 * 导出的是「数据 + 图片路径清单」：图片本身在本地沙箱里，导出文件里只记路径。
 * 清空数据会连本地图片文件一起删掉，所以这里做了两次确认。
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');
const storage = require('../../utils/storage.js');
const imageUtil = require('../../utils/image.js');
const cutout = require('../../utils/cutout.js');
const dateUtil = require('../../utils/date.js');

const VERSION = '1.0.0';
const DOCS_URL = 'https://www.looklog.vip/docs/intro';

Page({
  data: {
    version: VERSION,
    settings: { showLastWorn: true },
    stat: { clothing: 0, outfits: 0, inspirations: 0 },
    storageText: '',
    imageText: '',
    cutoutOn: false,
    cutoutUrl: '',
  },

  onLoad() {
    this.refresh();
    store.on(store.EVENTS.SETTINGS_CHANGE, this.onSettingsChange, this);
    store.on(store.EVENTS.CLOTHING_CHANGE, this.refreshStat, this);
    store.on(store.EVENTS.OUTFIT_CHANGE, this.refreshStat, this);
    store.on(store.EVENTS.INSPIRATION_CHANGE, this.refreshStat, this);
  },

  onShow() {
    // 图片占用这类信息只有回到本页时才需要重新算
    this.refreshStat();
    this.refreshStorage();
  },

  onUnload() {
    store.offByCtx(this);
  },

  /* ==================== 数据展示 ==================== */

  refresh() {
    const config = cutout.getConfig();
    this.setData({
      settings: db.getSettings(),
      cutoutOn: cutout.isConfigured(),
      cutoutUrl: config.apiUrl || '',
    });
    this.refreshStat();
    this.refreshStorage();
  },

  refreshStat() {
    this.setData({
      stat: {
        clothing: db.listClothing().length,
        outfits: db.listOutfits().length,
        inspirations: db.listInspirations().length,
      },
    });
  },

  refreshStorage() {
    const info = storage.getInfo();
    const images = imageUtil.getImagesStat();
    this.setData({
      storageText: info.currentSize + ' KB / ' + info.limitSize + ' KB',
      imageText: images.count + ' 张 · 约 ' + formatSize(images.size),
    });
  },

  onSettingsChange(settings) {
    this.setData({ settings: settings || db.getSettings() });
  },

  /* ==================== 显示设置 ==================== */

  onToggleLastWorn(e) {
    db.saveSettings({ showLastWorn: !!e.detail.value });
  },

  /* ==================== 导出 ==================== */

  onExport() {
    wx.showActionSheet({
      itemList: ['导出为 JSON 文件', '复制到剪贴板'],
      success: (res) => {
        if (res.tapIndex === 0) this.exportFile();
        else this.copyJson();
      },
      fail: () => {},
    });
  },

  buildJson() {
    return JSON.stringify(db.exportData(), null, 2);
  },

  exportFile() {
    let path = '';
    try {
      path = imageUtil.writeTextFile(
        imageUtil.exportDir(),
        '我的衣橱-' + dateUtil.today() + '.json',
        this.buildJson()
      );
    } catch (err) {
      console.error('[settings] 导出失败', err);
      wx.showToast({ title: '导出失败，请重试', icon: 'none' });
      return;
    }

    if (!wx.shareFileMessage) {
      wx.showModal({
        title: '已导出',
        content: '当前基础库不支持转发文件，文件已保存到：\n' + path,
        showCancel: false,
        confirmText: '知道了',
      });
      return;
    }

    wx.shareFileMessage({
      filePath: path,
      fileName: '我的衣橱.json',
      fail: () => {
        // 开发者工具 / 部分环境转发不可用，退回复制内容
        wx.showModal({
          title: '转发不可用',
          content: '文件已经生成在本地：\n' + path + '\n\n要不要把内容复制到剪贴板？',
          confirmText: '复制',
          success: (res) => {
            if (res.confirm) this.copyJson();
          },
        });
      },
    });
  },

  copyJson() {
    wx.setClipboardData({
      data: this.buildJson(),
      success: () => wx.showToast({ title: '已复制到剪贴板', icon: 'none' }),
    });
  },

  /* ==================== 清空数据 ==================== */

  onClearData() {
    wx.showModal({
      title: '清空数据',
      content: '会删除全部衣物、穿搭、灵感，以及本地保存的图片文件（设置保留）。此操作不可恢复。',
      confirmText: '继续',
      confirmColor: '#e0564f',
      success: (res) => {
        if (!res.confirm) return;
        // 删除量比较大，再确认一次
        wx.showModal({
          title: '再确认一次',
          content: '确定要清空全部数据吗？',
          confirmText: '清空',
          confirmColor: '#e0564f',
          success: (r2) => {
            if (!r2.confirm) return;
            db.clearAll();
            imageUtil.clearImages();
            this.refresh();
            wx.showToast({ title: '已清空', icon: 'success' });
          },
        });
      },
    });
  },

  /* ==================== 云端抠图配置 ==================== */

  onCutoutConfig() {
    const config = cutout.getConfig();
    wx.showModal({
      title: '云端抠图接口',
      editable: true,
      content: config.apiUrl || '',
      placeholderText: '留空 = 关闭，例如 https://example.com/api/cutout',
      success: (res) => {
        if (!res.confirm) return;
        const url = String(res.content || '').trim();

        if (!url) {
          cutout.setConfig({ enabled: false });
          this.refresh();
          wx.showToast({ title: '已关闭云端抠图', icon: 'none' });
          return;
        }
        if (url.indexOf('https://') !== 0) {
          wx.showToast({ title: '接口地址要以 https:// 开头', icon: 'none' });
          return;
        }

        wx.showModal({
          title: '接口 Key（可留空）',
          editable: true,
          content: config.apiKey || '',
          placeholderText: '服务端不需要鉴权就留空',
          success: (r2) => {
            if (!r2.confirm) return;
            cutout.setConfig({
              enabled: true,
              apiUrl: url,
              apiKey: String(r2.content || '').trim(),
            });
            this.refresh();
            wx.showModal({
              title: '还差一步',
              content:
                '接口域名要加到小程序后台「开发管理 → 开发设置 → 服务器域名」的 request / uploadFile 合法域名里，否则真机会提示域名不合法。',
              showCancel: false,
              confirmText: '知道了',
            });
          },
        });
      },
    });
  },

  /* ==================== 关于 ==================== */

  onOpenDocs() {
    wx.setClipboardData({
      data: DOCS_URL,
      success: () => {
        wx.showModal({
          title: '参考项目',
          content: 'LookLog 的链接已复制，粘贴到浏览器里就能打开。\n\n' + DOCS_URL,
          showCancel: false,
          confirmText: '知道了',
        });
      },
    });
  },
});

function formatSize(kb) {
  if (!kb) return '0 KB';
  if (kb < 1024) return kb + ' KB';
  return (kb / 1024).toFixed(1) + ' MB';
}
