/**
 * pages/fitting —— 试衣间
 *
 * 顶部是文件夹 tab：「搭配」（虚拟，对应全部穿搭）+ 各个灵感文件夹。
 *
 * 【搭配】把衣橱里的衣物拖到画布上拼一套：
 *  - 每件衣物是一个 movable-view：单指拖动交给 movable-view 自己处理（不 setData，跟手），
 *    双指捏合缩放 / 旋转在 bindtouchmove 里算，只有这时才 setData
 *  - 缩放锚点固定在捏合中点：记录手势开始时的图片中心与中点，按 scale 比例把中心推开，
 *    旋转角度用「当前夹角 - 起始夹角」做补偿，避免手指刚搭上去就跳一下
 *  - 摆位（x/y/scale/rotation/zIndex）存进穿搭的 canvasData；保存时用 canvas 画一张合成封面
 *  - 双指开始时把该层的 movable-view disabled 掉，等手指全部离开再恢复，
 *    否则 movable-view 自己的拖拽会和捏合打架（代价是捏合后需要重新按一下才能拖）
 *
 * 【灵感】网格展示灵感图：点击看大图，长按进入多选 → 关联衣物 / 加备注 / 移动 / 删除。
 * 灵感图与我们自己的图片文件一一对应，删除时一起清掉。
 *
 * 「我的搭配」列表按四季做了分类：上面一排胶囊（全部 / 春 / 夏 / 秋 / 冬）筛着看，
 * 缩略图左下角显示已标的季节，长按某一套可以直接「设置季节」（多选，不选表示四季都能穿）。
 *
 * 入口约定：别的页面要「在试衣间继续编辑某套搭配」时，先把 id 放进
 * store.setState({ pendingFitting: { outfitId } })，再 wx.switchTab 过来（tabBar 页不能带参数）。
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');
const dateUtil = require('../../utils/date.js');
const imageUtil = require('../../utils/image.js');

const MIN_SCALE = 0.3;
const MAX_SCALE = 4;
const SNAP_ANGLE = 4; // 接近 90 的整数倍时吸附，方便摆正
const EXPORT_RATIO = 3; // 合成封面相对画布区的倍数
const EXPORT_MAX_SIDE = 1600;
const MAX_IMPORT = 9;

Page({
  data: {
    folders: [],
    activeFolderId: db.OUTFIT_FOLDER.id,
    activeFolderName: db.OUTFIT_FOLDER.name,
    isOutfitTab: true,

    /* 搭配 */
    areaW: 0,
    areaH: 0,
    compW: 0, // 合成封面用的离屏画布尺寸（CSS 像素）
    compH: 0,
    layerSize: 140,
    layers: [],
    selectedId: '',
    selectedName: '',
    outfits: [],
    outfitSeason: db.ALL, // 「我的搭配」按季节筛选：全部 / 春 / 夏 / 秋 / 冬
    outfitSeasonChips: [],
    outfitCountText: '',
    hasOutfitFilter: false,
    loadedOutfitId: '',
    saving: false,

    /* 设置季节的弹层 */
    seasonSheet: { show: false, outfitId: '', chips: [] },

    /* 灵感 */
    inspirations: [],
    selectMode: false,
    selectedCount: 0,

    /* 选衣弹层 */
    showSelector: false,
    selectorSelected: [],
    selectorTitle: '添加衣物',
    selectorMode: 'stage', // stage | inspiration
  },

  onLoad() {
    this._poses = {}; // clothingId -> { x, y, scale, rotation, zIndex }
    this._dims = {}; // 图片路径 -> { width, height }
    this._imgCache = {}; // 图片路径 -> Promise<Image>（合成封面用）
    this._insp = {}; // inspirationId -> 灵感数据
    this._selectIds = [];
    this._gesture = null;
    this._buildToken = 0;

    this.setLayout();
    this.setData({ folders: db.listFittingFolders() });
    this.refreshOutfits();
    this.refreshInspirations();

    store.on(store.EVENTS.OUTFIT_CHANGE, this.refreshOutfits, this);
    store.on(store.EVENTS.CLOTHING_CHANGE, this.onClothingChange, this);
    store.on(store.EVENTS.INSPIRATION_CHANGE, this.refreshInspirations, this);
  },

  onReady() {
    // 捏合换算要用画布区在屏幕上的位置，元素渲染完成后量一次
    this.measureStage();
  },

  onShow() {
    // tabBar 页从别处切回来时不会重新 onLoad，刷新与新数据都在这里处理
    this.setData({ folders: db.listFittingFolders() });
    this.refreshOutfits();
    this.refreshInspirations();

    const pending = store.getState().pendingFitting;
    if (pending && pending.outfitId) {
      store.setState({ pendingFitting: null });
      this.setData({ activeFolderId: db.OUTFIT_FOLDER.id, isOutfitTab: true });
      this.loadOutfit(pending.outfitId);
    }
  },

  onUnload() {
    store.offByCtx(this);
  },

  /* ==================== 布局 ==================== */

  /**
   * 画布区尺寸：宽度铺满，高度按可用高度收（顶部 tab、底部操作栏、「我的搭配」都要留位置）。
   * 合成封面用的离屏 canvas 与它保持同样的宽高比，导出的图才和屏幕上看到的一致。
   */
  setLayout() {
    const app = getApp();
    const info = (app && app.globalData && app.globalData.systemInfo) || {};
    const winW = info.windowWidth || 375;
    const winH = info.windowHeight || 600;
    const areaW = Math.max(280, Math.round(winW - 24));
    const areaH = Math.max(
      240,
      Math.min(Math.round(areaW * 1.08), Math.round(winH - 250))
    );
    // 离屏画布按 dpr 反向放大：导出 3 倍图时正好打在画布的实际像素上，不糊也不浪费内存
    const dpr = info.pixelRatio || 2;
    const compScale = clamp(EXPORT_RATIO / dpr, 1, 3);
    this.setData({
      areaW,
      areaH,
      compW: Math.round(areaW * compScale),
      compH: Math.round(areaH * compScale),
      layerSize: Math.round(Math.min(areaW, areaH) * 0.44),
    });
  },

  measureStage() {
    this.createSelectorQuery()
      .select('#stage')
      .boundingClientRect((rect) => {
        if (rect) this._rect = rect;
      })
      .exec();
  },

  /* ==================== 顶部文件夹 tab ==================== */

  onTabTap(e) {
    const id = e.currentTarget.dataset.id;
    if (!id || id === this.data.activeFolderId) return;
    const folder = this.data.folders.find((item) => item.id === id);
    this.exitSelect();
    this.setData({
      activeFolderId: id,
      activeFolderName: folder ? folder.name : '',
      isOutfitTab: id === db.OUTFIT_FOLDER.id,
    });
    if (id !== db.OUTFIT_FOLDER.id) this.refreshInspirations();
  },

  onTabLongPress(e) {
    const id = e.currentTarget.dataset.id;
    if (id === db.OUTFIT_FOLDER.id) {
      wx.showToast({ title: '「搭配」是固定分类，不能改名', icon: 'none' });
      return;
    }
    const folder = db.getFolder(id);
    if (!folder) return;
    wx.showActionSheet({
      itemList: ['重命名', '删除文件夹'],
      success: (res) => {
        if (res.tapIndex === 0) this.renameFolder(folder);
        else this.deleteFolder(folder);
      },
      fail: () => {},
    });
  },

  onAddFolder() {
    wx.showModal({
      title: '新建文件夹',
      editable: true,
      placeholderText: '例如：秋冬灵感',
      success: (res) => {
        if (!res.confirm) return;
        const name = String(res.content || '').trim();
        if (!name) {
          wx.showToast({ title: '名字不能为空', icon: 'none' });
          return;
        }
        const folder = db.addFolder(name);
        this.setData({
          folders: db.listFittingFolders(),
          activeFolderId: folder.id,
          activeFolderName: folder.name,
          isOutfitTab: false,
        });
        this.refreshInspirations();
      },
    });
  },

  renameFolder(folder) {
    wx.showModal({
      title: '重命名',
      editable: true,
      content: folder.name,
      success: (res) => {
        if (!res.confirm) return;
        const name = String(res.content || '').trim();
        if (!name) return;
        db.renameFolder(folder.id, name);
        this.setData({
          folders: db.listFittingFolders(),
          activeFolderName: this.data.activeFolderId === folder.id ? name : this.data.activeFolderName,
        });
      },
    });
  },

  deleteFolder(folder) {
    wx.showModal({
      title: '删除文件夹',
      content: '文件夹里的灵感会移到默认文件夹，灵感图本身不会被删掉。',
      confirmText: '删除',
      confirmColor: '#e0564f',
      success: (res) => {
        if (!res.confirm) return;
        if (!db.deleteFolder(folder.id)) {
          wx.showToast({ title: '默认文件夹不能删除', icon: 'none' });
          return;
        }
        const folders = db.listFittingFolders();
        const fallback = folders[folders.length - 1];
        const needSwitch = this.data.activeFolderId === folder.id;
        this.setData({
          folders,
          activeFolderId: needSwitch ? fallback.id : this.data.activeFolderId,
          activeFolderName: needSwitch ? fallback.name : this.data.activeFolderName,
          isOutfitTab: needSwitch ? fallback.id === db.OUTFIT_FOLDER.id : this.data.isOutfitTab,
        });
        this.refreshInspirations();
      },
    });
  },

  /* ==================== 搭配：图层 ==================== */

  /** 衣物数据变了（新增 / 编辑 / 删除）：把画布上已经不存在的衣物拿掉 */
  onClothingChange() {
    if (!this.data.layers.length) return;
    this.renderLayers();
  },

  /** 按 _poses 里记着的衣物重建图层 */
  renderLayers() {
    const items = db.listClothingByIds(Object.keys(this._poses));
    const alive = {};
    items.forEach((item) => {
      alive[item.id] = true;
    });
    Object.keys(this._poses).forEach((id) => {
      if (!alive[id]) delete this._poses[id];
    });

    const token = (this._buildToken += 1);
    Promise.all(
      items.map((item) =>
        this.dimsOf(item.coverImage || item.originalImage).then((dims) => ({ item, dims }))
      )
    )
      .then((pairs) => {
        if (token !== this._buildToken) return; // 期间又改过，丢弃这次结果
        const layers = this.buildLayers(pairs);
        const selected = layers.find((layer) => layer.id === this.data.selectedId);
        this.setData({
          layers,
          selectedId: selected ? selected.id : '',
          selectedName: selected ? selected.name : '',
        });
      })
      .catch((err) => {
        console.error('[fitting] 图层构建失败', err);
      });
  },

  buildLayers(pairs) {
    const areaW = this.data.areaW;
    const areaH = this.data.areaH;
    const list = pairs
      .map(({ item, dims }) => {
        const size = this.sizeOf(dims);
        const pose = this._poses[item.id] || this.cascadePose(Object.keys(this._poses).length);
        this._poses[item.id] = pose;

        const layer = {
          id: item.id,
          clothingId: item.id,
          name: item.name,
          image: item.coverImage || item.originalImage || '',
          w: size.w,
          h: size.h,
          x: clamp(pose.x, 0, Math.max(0, areaW - size.w)),
          y: clamp(pose.y, 0, Math.max(0, areaH - size.h)),
          scale: pose.scale,
          rotation: pose.rotation,
          zIndex: pose.zIndex,
          selected: item.id === this.data.selectedId,
          disabled: false,
        };
        return layer;
      })
      .sort((a, b) => a.zIndex - b.zIndex);

    // 归一化层级，DOM 顺序与 z 值保持一致，重绘 / 导出都不会错
    list.forEach((layer, i) => {
      layer.z = i + 1;
      const pose = this._poses[layer.id];
      pose.x = layer.x;
      pose.y = layer.y;
      pose.zIndex = layer.z;
    });
    return list;
  },

  sizeOf(dims) {
    const box = this.data.layerSize || 140;
    const w = (dims && dims.width) || box;
    const h = (dims && dims.height) || box;
    const ratio = w / h;
    if (ratio >= 1) return { w: box, h: Math.max(24, Math.round(box / ratio)) };
    return { w: Math.max(24, Math.round(box * ratio)), h: box };
  },

  /** 新加的衣物按阶梯错开摆，不会完全叠在一起 */
  cascadePose(index) {
    const step = 16;
    return {
      x: 14 + (index % 5) * step,
      y: 14 + (index % 5) * step,
      scale: 1,
      rotation: 0,
      zIndex: index + 1,
    };
  },

  /** 图片尺寸（按路径缓存，getImageInfo 是异步的） */
  dimsOf(path) {
    if (!path) return Promise.resolve({ width: 0, height: 0 });
    if (this._dims[path]) return Promise.resolve(this._dims[path]);
    return new Promise((resolve) => {
      wx.getImageInfo({
        src: path,
        success: (res) => {
          this._dims[path] = { width: res.width, height: res.height };
          resolve(this._dims[path]);
        },
        fail: () => {
          // 图挂了也别让图层消失，退回正方形占位
          const fallback = { width: 0, height: 0 };
          this._dims[path] = fallback;
          resolve(fallback);
        },
      });
    });
  },

  /* ==================== 搭配：选中与手势 ==================== */

  syncSelected(id) {
    const layer = this.data.layers.find((item) => item.id === id);
    const patch = {
      selectedId: id || '',
      selectedName: layer ? layer.name : '',
    };
    this.data.layers.forEach((item, i) => {
      patch['layers[' + i + '].selected'] = item.id === id;
    });
    this.setData(patch);
  },

  onLayerTap(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    if (id === this.data.selectedId) this.syncSelected('');
    else this.syncSelected(id);
  },

  /**
   * 单指拖动是 movable-view 自己处理的（不 setData，所以跟手），
   * 这里只把最终位置同步回 _poses，保存时才拿得到用户实际摆的位置。
   */
  onLayerChange(e) {
    const id = e.currentTarget.dataset.id;
    const detail = e.detail || {};
    const pose = this._poses[id];
    if (!pose || typeof detail.x !== 'number' || typeof detail.y !== 'number') return;
    pose.x = detail.x;
    pose.y = detail.y;
  },

  onStageTap() {
    if (this.data.selectedId) this.syncSelected('');
  },

  onLayerTouchStart(e) {
    const touches = e.touches || [];
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    if (touches.length === 1) {
      // 单指：交给 movable-view 自己拖，顺手选中它
      if (id !== this.data.selectedId) this.syncSelected(id);
      return;
    }
    if (touches.length < 2) return;

    const layer = this.data.layers.find((item) => item.id === id);
    if (!layer) return;
    if (id !== this.data.selectedId) this.syncSelected(id);

    const rect = this._rect || { left: 0, top: 0 };
    // 位置以 _poses 为准：单指拖动时 data 里的 x/y 是旧的（拖拽不 setData）
    const pose = this._poses[id] || {};
    const baseX = typeof pose.x === 'number' ? pose.x : layer.x;
    const baseY = typeof pose.y === 'number' ? pose.y : layer.y;
    this._gesture = {
      id,
      dist: distance(touches[0], touches[1]),
      angle: angleOf(touches[0], touches[1]),
      mid: midOf(touches[0], touches[1]),
      scale: layer.scale,
      rotation: layer.rotation,
      center: {
        x: rect.left + baseX + layer.w / 2,
        y: rect.top + baseY + layer.h / 2,
      },
    };

    // 双指期间禁掉 movable-view 自己的拖拽，免得和捏合打架
    const index = this.data.layers.findIndex((item) => item.id === id);
    if (index >= 0) this.setData({ ['layers[' + index + '].disabled']: true });
  },

  onLayerTouchMove(e) {
    const gesture = this._gesture;
    if (!gesture) return;
    const touches = e.touches || [];
    if (touches.length < 2) return;

    const index = this.data.layers.findIndex((item) => item.id === gesture.id);
    if (index < 0) return;
    const layer = this.data.layers[index];
    const rect = this._rect || { left: 0, top: 0 };

    const dist = distance(touches[0], touches[1]);
    const angle = angleOf(touches[0], touches[1]);
    const mid = midOf(touches[0], touches[1]);

    const scale = clamp(
      gesture.dist > 0 ? gesture.scale * (dist / gesture.dist) : gesture.scale,
      MIN_SCALE,
      MAX_SCALE
    );
    const rotation = snapAngle(gesture.rotation + (angle - gesture.angle));

    // 以捏合中点为锚点缩放：中点在屏幕上的位置不动，图片中心按比例往外推
    const ratio = gesture.scale > 0 ? scale / gesture.scale : 1;
    const centerX = mid.x + (gesture.center.x - mid.x) * ratio;
    const centerY = mid.y + (gesture.center.y - mid.y) * ratio;
    const x = clamp(centerX - rect.left - layer.w / 2, 0, Math.max(0, this.data.areaW - layer.w));
    const y = clamp(centerY - rect.top - layer.h / 2, 0, Math.max(0, this.data.areaH - layer.h));

    const pose = this._poses[layer.id];
    if (pose) {
      pose.x = x;
      pose.y = y;
      pose.scale = scale;
      pose.rotation = rotation;
    }

    const patch = {};
    patch['layers[' + index + '].x'] = x;
    patch['layers[' + index + '].y'] = y;
    patch['layers[' + index + '].scale'] = scale;
    patch['layers[' + index + '].rotation'] = rotation;
    this.setData(patch);
  },

  onLayerTouchEnd(e) {
    if (!this._gesture) return;
    const touches = (e && e.touches) || [];
    // 还有两根手指在屏幕上，说明捏合还没结束
    if (touches.length >= 2) return;

    const id = this._gesture.id;
    this._gesture = null;
    const index = this.data.layers.findIndex((item) => item.id === id);
    if (index >= 0) this.setData({ ['layers[' + index + '].disabled']: false });
  },

  onLayerToFront() {
    this.reorderLayer('front');
  },

  onLayerToBack() {
    this.reorderLayer('back');
  },

  reorderLayer(to) {
    const id = this.data.selectedId;
    if (!id) return;
    const max = this.data.layers.length + 1;
    const pose = this._poses[id];
    if (!pose) return;
    pose.zIndex = to === 'front' ? max : -1;
    this.renderLayers();
  },

  /** 复位：缩放与旋转回默认，位置放到中间偏上的位置 */
  onLayerReset() {
    const id = this.data.selectedId;
    if (!id) return;
    const layer = this.data.layers.find((item) => item.id === id);
    const pose = this._poses[id];
    if (!layer || !pose) return;
    pose.scale = 1;
    pose.rotation = 0;
    pose.x = Math.round((this.data.areaW - layer.w) / 2);
    pose.y = Math.round((this.data.areaH - layer.h) / 2);
    this.renderLayers();
  },

  onRemoveLayer(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    delete this._poses[id];
    this.renderLayers();
    wx.showToast({ title: '已从画布移除', icon: 'none' });
  },

  /* ==================== 搭配：增删与保存 ==================== */

  onAddClothing() {
    this.setData({
      showSelector: true,
      selectorMode: 'stage',
      selectorTitle: '添加衣物',
      selectorSelected: this.data.layers.map((layer) => layer.clothingId),
    });
  },

  /** 弹层回传的是画布上应该有的衣物清单：没摆位的补上，被取消的拿掉 */
  syncStageClothing(ids) {
    const keep = {};
    ids.forEach((id) => {
      keep[id] = true;
      if (!this._poses[id]) this._poses[id] = this.cascadePose(Object.keys(this._poses).length);
    });
    Object.keys(this._poses).forEach((id) => {
      if (!keep[id]) delete this._poses[id];
    });
    this.renderLayers();
  },

  onClearStage() {
    if (!this.data.layers.length) return;
    wx.showModal({
      title: '清空画布',
      content: '画布上的衣物会全部拿掉，已经保存过的搭配不受影响。',
      confirmText: '清空',
      success: (res) => {
        if (!res.confirm) return;
        this._poses = {};
        this._buildToken += 1;
        this.setData({
          layers: [],
          selectedId: '',
          selectedName: '',
          loadedOutfitId: '',
        });
      },
    });
  },

  onSaveOutfit() {
    if (this.data.saving) return;
    if (!this.data.layers.length) {
      wx.showToast({ title: '画布上还没有衣物', icon: 'none' });
      return;
    }

    this.setData({ saving: true });
    wx.showLoading({ title: '生成封面…', mask: true });

    this.composeCover()
      .then((tempPath) => imageUtil.saveImage(tempPath, { prefix: 'outfit-cover' }))
      .then((saved) => {
        const old = this.data.loadedOutfitId ? db.getOutfit(this.data.loadedOutfitId) : null;
        const outfit = db.saveOutfit({
          id: old ? old.id : undefined,
          clothingIds: this.data.layers.map((layer) => layer.clothingId),
          // 位置以 _poses 为准（单指拖动不会 setData，data 里的 x/y 可能是旧的）
          canvasData: this.data.layers.map((layer) => {
            const pose = this._poses[layer.clothingId] || {};
            return {
              clothingId: layer.clothingId,
              x: typeof pose.x === 'number' ? pose.x : layer.x,
              y: typeof pose.y === 'number' ? pose.y : layer.y,
              scale: layer.scale,
              rotation: layer.rotation,
              zIndex: layer.z,
            };
          }),
          cover: saved.path,
          note: old ? old.note : '',
          date: old ? old.date : dateUtil.today(),
          createTime: old ? old.createTime : undefined,
        });

        // 旧封面如果只被这套搭配用着，替换后就没用了
        const oldCover = old ? old.cover : '';
        if (oldCover && oldCover !== saved.path && !db.isImageInUse(oldCover)) {
          imageUtil.removeFile(oldCover);
        }

        wx.hideLoading();
        this.setData({ saving: false, loadedOutfitId: outfit.id });
        if (wx.vibrateShort) wx.vibrateShort({ type: 'light', fail() {} });
        wx.showToast({ title: old ? '已更新搭配' : '已保存搭配', icon: 'success' });
      })
      .catch((err) => {
        wx.hideLoading();
        this.setData({ saving: false });
        console.error('[fitting] 保存搭配失败', err);
        wx.showToast({ title: (err && err.message) || '保存失败', icon: 'none' });
      });
  },

  onDuplicate() {
    if (!this.data.loadedOutfitId) {
      wx.showToast({ title: '先保存或从下面选中一套搭配', icon: 'none' });
      return;
    }
    const copy = db.duplicateOutfit(this.data.loadedOutfitId, { date: dateUtil.today() });
    if (!copy) return;
    this.setData({ loadedOutfitId: copy.id });
    this.refreshOutfits();
    wx.showToast({ title: '已复制成一套新搭配', icon: 'none' });
  },

  /* ==================== 搭配：已保存列表 ==================== */

  refreshOutfits() {
    const total = db.listOutfits().length;
    const season = this.data.outfitSeason;
    const filtering = !!season && season !== db.ALL;

    const outfits = db.listOutfits({ season }).map((outfit) => {
      const items = db.listClothingByIds(outfit.clothingIds);
      const first = items.length ? items[0].coverImage || items[0].originalImage || '' : '';
      return {
        id: outfit.id,
        cover: outfit.cover || first,
        count: items.length,
        seasonText: (outfit.seasons || []).join('/'),
        dateLabel: dateUtil.friendlyDate(outfit.date),
      };
    });

    this.setData({
      outfits,
      outfitSeasonChips: [db.ALL].concat(db.SEASONS),
      hasOutfitFilter: filtering,
      outfitCountText: filtering
        ? outfits.length + ' 套 · 全部 ' + total + ' 套'
        : outfits.length + ' 套 · 长按可以删除',
    });
  },

  /** 「我的搭配」的四季分类：点胶囊只看那个季节，点「全部」看全部 */
  onOutfitSeasonTap(e) {
    const value = e.currentTarget.dataset.value;
    if (!value || value === this.data.outfitSeason) return;
    this.setData({ outfitSeason: value });
    this.refreshOutfits();
  },

  onLoadOutfit(e) {
    this.loadOutfit(e.currentTarget.dataset.id);
  },

  loadOutfit(id) {
    const outfit = id ? db.getOutfit(id) : null;
    if (!outfit) {
      wx.showToast({ title: '这套搭配已不存在', icon: 'none' });
      return;
    }

    this._poses = {};
    (outfit.canvasData || []).forEach((item) => {
      this._poses[item.clothingId] = {
        x: item.x,
        y: item.y,
        scale: item.scale || 1,
        rotation: item.rotation || 0,
        zIndex: item.zIndex || 1,
      };
    });

    // 只在穿搭编辑里选进来、还没在试衣间摆过的衣物，按级联补个位置
    let index = Object.keys(this._poses).length;
    (outfit.clothingIds || []).forEach((cid) => {
      if (!this._poses[cid]) this._poses[cid] = this.cascadePose(index++);
    });

    this.setData({ loadedOutfitId: outfit.id, selectedId: '', selectedName: '' });
    this.renderLayers();
  },

  onOutfitLongPress(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    wx.showActionSheet({
      itemList: ['在画布中打开', '设置季节', '删除这套搭配'],
      success: (res) => {
        if (res.tapIndex === 0) this.loadOutfit(id);
        else if (res.tapIndex === 1) this.openSeasonSheet(id);
        else this.deleteOutfit(id);
      },
      fail: () => {},
    });
  },

  /* ==================== 搭配：四季分类 ==================== */

  /** 弹层里改某一套搭配的季节（多选，不选 = 四季都能穿） */
  openSeasonSheet(id) {
    const outfit = db.getOutfit(id);
    if (!outfit) return;
    this.setData({
      seasonSheet: {
        show: true,
        outfitId: id,
        chips: this.buildSeasonChips(outfit.seasons),
      },
    });
  },

  buildSeasonChips(selected) {
    const list = selected || [];
    return db.SEASONS.map((value) => ({ value, active: list.indexOf(value) >= 0 }));
  },

  onSeasonSheetTap(e) {
    const value = e.currentTarget.dataset.value;
    const chips = this.data.seasonSheet.chips.map((chip) =>
      chip.value === value ? { value: chip.value, active: !chip.active } : chip
    );
    this.setData({ 'seasonSheet.chips': chips });
  },

  onSeasonSheetClose() {
    this.setData({ seasonSheet: { show: false, outfitId: '', chips: [] } });
  },

  /** 弹层遮罩上吃掉 touchmove，避免背后页面跟着滚 */
  noop() {},

  onSeasonSheetSave() {
    const sheet = this.data.seasonSheet;
    if (!sheet.outfitId) return;
    const seasons = sheet.chips
      .filter((chip) => chip.active)
      .map((chip) => chip.value)
      .sort((a, b) => db.SEASONS.indexOf(a) - db.SEASONS.indexOf(b));

    db.updateOutfit(sheet.outfitId, { seasons });
    this.onSeasonSheetClose();
    wx.showToast({
      title: seasons.length ? '已标记 ' + seasons.join('/') : '已清空季节标记',
      icon: 'none',
    });
  },

  deleteOutfit(id) {
    const outfit = db.getOutfit(id);
    if (!outfit) return;
    wx.showModal({
      title: '删除搭配',
      content: '删除后不可恢复（关联的衣物不会被删除）。',
      confirmText: '删除',
      confirmColor: '#e0564f',
      success: (res) => {
        if (!res.confirm) return;
        const cover = outfit.cover;
        db.deleteOutfit(id);
        if (cover && !db.isImageInUse(cover)) imageUtil.removeFile(cover);
        // 正在编辑的就是这套的话，画布留着，但之后再保存会新建一套
        const patch = {};
        if (this.data.loadedOutfitId === id) patch.loadedOutfitId = '';
        this.setData(patch);
        wx.showToast({ title: '已删除', icon: 'none' });
      },
    });
  },

  /* ==================== 搭配：合成封面 ==================== */

  /**
   * 把画布区画成一张图：皮肤是透明背景，衣物按 z 顺序、各自的缩放旋转画上去。
   * 画布区与离屏 canvas 宽高比一致，所以导出的封面和屏幕上看到的一致。
   */
  composeCover() {
    const comp = this.selectComponent('#composer');
    if (!comp) return Promise.reject(new Error('画布组件未就绪'));

    const areaW = this.data.areaW;
    const areaH = this.data.areaH;
    const k = Math.min(EXPORT_RATIO, EXPORT_MAX_SIDE / Math.max(areaW, areaH));

    return comp.whenReady().then((metrics) => {
      const ctx = metrics.ctx;
      const sx = metrics.canvas.width / areaW;
      const sy = metrics.canvas.height / areaH;

      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, metrics.canvas.width, metrics.canvas.height);
      // 之后一律用「画布区坐标」作画
      ctx.setTransform(sx, 0, 0, sy, 0, 0);
      ctx.globalCompositeOperation = 'source-over';

      const layers = this.data.layers.slice().sort((a, b) => a.z - b.z);
      return layers
        .reduce(
          (chain, layer) =>
            chain.then(() => {
              if (!layer.image) return null;
              return this.imageOf(comp, layer.image).then((img) => {
                ctx.save();
                ctx.translate(layer.x + layer.w / 2, layer.y + layer.h / 2);
                ctx.rotate((layer.rotation * Math.PI) / 180);
                ctx.scale(layer.scale, layer.scale);
                ctx.drawImage(img, -layer.w / 2, -layer.h / 2, layer.w, layer.h);
                ctx.restore();
              });
            }),
          Promise.resolve()
        )
        .then(() =>
          comp.exportToTempFile({
            destWidth: Math.round(areaW * k),
            destHeight: Math.round(areaH * k),
            fileType: 'png',
          })
        );
    });
  },

  imageOf(comp, path) {
    if (!this._imgCache[path]) {
      this._imgCache[path] = comp.createImage(path).catch((err) => {
        delete this._imgCache[path];
        throw err;
      });
    }
    return this._imgCache[path];
  },

  /* ==================== 灵感 ==================== */

  refreshInspirations() {
    if (this.data.isOutfitTab) return;
    const list = db.listInspirations(this.data.activeFolderId);
    const selected = this._selectIds;
    this._insp = {};

    const items = list.map((item) => {
      this._insp[item.id] = item;
      return {
        id: item.id,
        thumb: item.images[0] || '',
        imageCount: item.images.length,
        note: item.note || item.title || '',
        clothingCount: (item.clothingIds || []).length,
        clothingText: (item.clothingIds || []).length
          ? '关联 ' + item.clothingIds.length + ' 件衣物'
          : '未关联衣物',
        selected: selected.indexOf(item.id) >= 0,
      };
    });

    this.setData({ inspirations: items, selectedCount: selected.length });
  },

  onImportImages() {
    const folderId = this.data.activeFolderId;
    if (folderId === db.OUTFIT_FOLDER.id) return;

    const created = [];
    imageUtil
      .chooseImage({ count: MAX_IMPORT })
      .then((paths) =>
        paths.reduce(
          (chain, path) =>
            chain.then(() =>
              imageUtil.saveImage(path, { prefix: 'insp' }).then((saved) => {
                created.push(saved.path);
              })
            ),
          Promise.resolve()
        )
      )
      .then(() => {
        if (!created.length) return;
        db.addInspiration({ folderId, images: created });
        wx.showToast({ title: '已导入 ' + created.length + ' 张', icon: 'none' });
      })
      .catch((err) => {
        // 中途失败的话，已经落盘的文件别留着（用户没看到这批图，留着也没人管）
        imageUtil.removeFiles(created);
        if (imageUtil.isCancel(err)) return;
        console.error('[fitting] 导入灵感图失败', err);
        wx.showToast({ title: '导入失败，请重试', icon: 'none' });
      });
  },

  onInspirationTap(e) {
    const id = e.currentTarget.dataset.id;
    const item = this._insp[id];
    if (!item) return;

    if (this.data.selectMode) {
      this.toggleSelect(id);
      return;
    }
    if (!item.images.length) return;
    wx.previewImage({ urls: item.images, current: item.images[0] });
  },

  onInspirationLongPress(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    if (wx.vibrateShort) wx.vibrateShort({ type: 'medium', fail() {} });
    if (this._selectIds.indexOf(id) < 0) this._selectIds.push(id);
    this.setData({ selectMode: true });
    this.refreshInspirations();
  },

  toggleSelect(id) {
    const index = this._selectIds.indexOf(id);
    if (index >= 0) this._selectIds.splice(index, 1);
    else this._selectIds.push(id);
    if (!this._selectIds.length) {
      this.exitSelect();
      return;
    }
    this.refreshInspirations();
  },

  exitSelect() {
    this._selectIds = [];
    this.setData({ selectMode: false, selectedCount: 0 });
    if (!this.data.isOutfitTab) this.refreshInspirations();
  },

  /** 多选栏上的「取消」 */
  onExitSelect() {
    this.exitSelect();
  },

  /** 多选时的目标灵感（去掉已经被删掉的） */
  selectTargets() {
    return this._selectIds.map((id) => db.getInspiration(id)).filter(Boolean);
  },

  onLinkClothing() {
    const targets = this.selectTargets();
    if (!targets.length) return;
    const selected = [];
    targets.forEach((item) => {
      (item.clothingIds || []).forEach((id) => {
        if (selected.indexOf(id) < 0) selected.push(id);
      });
    });
    this.setData({
      showSelector: true,
      selectorMode: 'inspiration',
      selectorTitle: '关联衣物',
      selectorSelected: selected,
    });
  },

  applyInspirationClothing(ids) {
    const targets = this.selectTargets();
    if (!targets.length) return;

    if (targets.length === 1) {
      db.updateInspiration(targets[0].id, { clothingIds: ids });
    } else {
      // 多张一起关联：保留各自原有的关联，再并上这次选的
      targets.forEach((item) => {
        const merged = (item.clothingIds || []).slice();
        ids.forEach((id) => {
          if (merged.indexOf(id) < 0) merged.push(id);
        });
        db.updateInspiration(item.id, { clothingIds: merged });
      });
    }

    wx.showToast({ title: '已关联衣物', icon: 'none' });
    this.exitSelect();
  },

  onEditNote() {
    const targets = this.selectTargets();
    if (targets.length !== 1) {
      wx.showToast({ title: '一次只能改一张的备注', icon: 'none' });
      return;
    }
    const item = targets[0];
    wx.showModal({
      title: '灵感备注',
      editable: true,
      content: item.note || '',
      placeholderText: '这套想怎么穿？',
      success: (res) => {
        if (!res.confirm) return;
        db.updateInspiration(item.id, { note: String(res.content || '').trim() });
        this.exitSelect();
        wx.showToast({ title: '备注已保存', icon: 'none' });
      },
    });
  },

  onMoveInspiration() {
    const targets = this.selectTargets();
    if (!targets.length) return;

    const folders = db.listFolders().filter((folder) => folder.id !== this.data.activeFolderId);
    if (!folders.length) {
      wx.showToast({ title: '还没有别的文件夹', icon: 'none' });
      return;
    }
    // showActionSheet 最多 6 项，超出的先不展示（够用，也没必要再造一个弹层）
    const visible = folders.slice(0, 6);
    wx.showActionSheet({
      itemList: visible.map((folder) => folder.name),
      success: (res) => {
        const folder = visible[res.tapIndex];
        if (!folder) return;
        targets.forEach((item) => db.updateInspiration(item.id, { folderId: folder.id }));
        wx.showToast({ title: '已移动到「' + folder.name + '」', icon: 'none' });
        this.exitSelect();
      },
      fail: () => {},
    });
  },

  onDeleteInspirations() {
    const targets = this.selectTargets();
    if (!targets.length) return;
    wx.showModal({
      title: '删除灵感',
      content: '会同时删掉 ' + targets.length + ' 组灵感及其图片，不可恢复。',
      confirmText: '删除',
      confirmColor: '#e0564f',
      success: (res) => {
        if (!res.confirm) return;
        targets.forEach((item) => {
          imageUtil.removeFiles(item.images);
          db.deleteInspiration(item.id);
        });
        this.exitSelect();
        wx.showToast({ title: '已删除', icon: 'none' });
      },
    });
  },

  /* ==================== 选衣弹层 ==================== */

  onSelectorClose() {
    this.setData({ showSelector: false });
  },

  onSelectorConfirm(e) {
    const ids = (e.detail && e.detail.ids) || [];
    const mode = this.data.selectorMode;
    this.setData({ showSelector: false });
    if (mode === 'inspiration') this.applyInspirationClothing(ids);
    else this.syncStageClothing(ids);
  },
});

/* ==================== 小工具 ==================== */

function clamp(value, min, max) {
  if (min > max) return min;
  return Math.max(min, Math.min(max, value));
}

function distance(a, b) {
  return Math.sqrt((a.pageX - b.pageX) * (a.pageX - b.pageX) + (a.pageY - b.pageY) * (a.pageY - b.pageY));
}

function angleOf(a, b) {
  return (Math.atan2(b.pageY - a.pageY, b.pageX - a.pageX) * 180) / Math.PI;
}

function midOf(a, b) {
  return { x: (a.pageX + b.pageX) / 2, y: (a.pageY + b.pageY) / 2 };
}

/** 把角度收敛到 [-180, 180)，避免连续旋转累积出很大的数值 */
function wrapAngle(angle) {
  let value = angle % 360;
  if (value >= 180) value -= 360;
  if (value < -180) value += 360;
  return value;
}

/** 接近水平 / 垂直时轻微吸附，摆正不用靠手感 */
function snapAngle(angle) {
  const wrapped = wrapAngle(angle);
  const target = Math.round(wrapped / 90) * 90;
  if (Math.abs(wrapped - target) <= SNAP_ANGLE) return wrapAngle(target);
  return wrapped;
}
