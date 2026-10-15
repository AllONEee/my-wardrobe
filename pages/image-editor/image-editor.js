/**
 * pages/image-editor —— 抠图 / 图片编辑
 *
 * 进入方式（调用方约定）：/pages/image-editor/image-editor?src=<encodeURIComponent 后的图片路径>
 * 回传方式：this.getOpenerEventChannel().emit('done', { path, originalPath, crop })
 *          path 是 canvas 导出的临时文件路径（PNG，带透明通道），由调用方负责落盘
 *
 * 坐标系约定（这一页最容易出错的地方，统一在这里说清楚）：
 *   - 画布坐标系：canvas 元素的 CSS 像素，原点在左上角。触摸事件的 x/y 就是这个坐标系。
 *   - 图像坐标系：原图自身的像素坐标，原点在图片左上角。
 *   - 笔画、裁剪框一律用「图像坐标」记录，所以缩放/平移之后重绘、导出都不会错位。
 *
 * 渲染方式：所有内容都在「图像坐标系」里描述，绘制前统一套一次变换（_applyTransform）：
 *   - 查看模式：dpr 变换 + 居中 + fitScale × 手势缩放 + 平移
 *   - 导出模式：把裁剪区域拉伸铺满画布，导出时再按比例还原（这样导出的图没有多余留白）
 * 撤销：ops 栈记录每一次操作（擦除/画笔是路径点，裁剪是矩形，云端抠图是上一张底图），
 *      撤销就是弹出栈顶后整体重绘，逻辑简单且不会累积误差。
 *
 * 画布相关的事（取节点、按 dpr 定尺寸、加载图片、导出临时文件、触摸事件转发）都交给
 * components/image-canvas，这一页只负责「画什么」和手势语义。
 */
const cutout = require('../../utils/cutout.js');

const MODE = { ERASE: 'erase', BRUSH: 'brush', CROP: 'crop' };
const SIZE_PRESETS = [
  { value: 8, label: '细' },
  { value: 16, label: '中' },
  { value: 28, label: '粗' },
];
const MAX_ZOOM = 8; // 相对于「适应屏幕」的最大放大倍数
const MIN_CROP = 24; // 裁剪框最小边长（图像坐标）
const EXPORT_MAX_SIDE = 1600; // 导出长边上限，控制文件体积

const MODE_HINT = {
  [MODE.ERASE]: '手指涂抹擦掉背景，双指捏合可放大细修',
  [MODE.BRUSH]: '涂回被擦掉的部分，双指捏合可放大细修',
  [MODE.CROP]: '拖动框选要保留的区域，确定时按此区域导出',
};

Page({
  data: {
    mode: MODE.ERASE,
    sizes: SIZE_PRESETS,
    brushSize: SIZE_PRESETS[1].value,
    canUndo: false,
    hasCrop: false,
    cropStyle: '',
    hint: MODE_HINT[MODE.ERASE],
    loading: true,
    srcPath: '',
  },

  onLoad(options) {
    let src = (options && options.src) || '';
    try {
      src = decodeURIComponent(src);
    } catch (err) {
      console.warn('[image-editor] src 解码失败，按原样使用', err);
    }

    this._ops = [];
    this._view = { scale: 1, tx: 0, ty: 0 };
    this._basePath = src;
    this._stroke = null;
    this._cropStart = null;
    this._cropPreview = null;
    this._pinching = false;
    this._pinch = null;
    this._blockDraw = false;
    this._busy = false;
    this._exporting = false;

    this.setData({ srcPath: src });
  },

  onReady() {
    this.initCanvas();
  },

  /* ==================== 初始化 ==================== */

  initCanvas() {
    const comp = this.selectComponent('#editor');
    if (!comp) {
      wx.showToast({ title: '画布初始化失败', icon: 'none' });
      return;
    }
    this._comp = comp;

    comp
      .whenReady()
      .then((metrics) => {
        this._canvas = metrics.canvas;
        this._ctx = metrics.ctx;
        this._dpr = metrics.dpr;
        this._cw = metrics.width;
        this._ch = metrics.height;
        return this.loadBase(this.data.srcPath);
      })
      .then(() => {
        this.recalcFit();
        this._view = { scale: 1, tx: 0, ty: 0 };
        this.setData({ loading: false });
        this.renderAll();
      })
      .catch((err) => {
        console.error('[image-editor] 底图加载失败', err);
        this.setData({ loading: false });
        wx.showToast({ title: '画布或图片加载失败', icon: 'none' });
      });
  },

  /** 加载底图（canvas.createImage，2D 接口，由 image-canvas 组件提供） */
  loadBase(path) {
    if (!this._comp || !path) return Promise.reject(new Error('缺少图片路径'));
    // 拿到的 img 要一直留着（底图与画笔恢复都要用），所以存在页面上而不是组件里
    return this._comp.createImage(path).then((img) => {
      this._base = img;
      this._imgW = img.width;
      this._imgH = img.height;
      return img;
    });
  },

  recalcFit() {
    this._fitScale = Math.min(this._cw / this._imgW, this._ch / this._imgH);
  },

  /* ==================== 变换与坐标 ==================== */

  /** 当前的「图像坐标 -> 画布坐标」变换，写成函数是为了让临时层复用同一套 */
  setViewTransform() {
    const dpr = this._dpr;
    const k = this._fitScale * this._view.scale;
    this._applyTransform = (c) => {
      c.setTransform(dpr, 0, 0, dpr, 0, 0);
      c.translate(this._cw / 2 + this._view.tx, this._ch / 2 + this._view.ty);
      c.scale(k, k);
      c.translate(-this._imgW / 2, -this._imgH / 2);
    };
  },

  /**
   * 导出用的变换：把裁剪区域拉伸铺满整块画布。
   * 导出时再把 canvas 的整幅内容缩放到 rect 的尺寸，于是导出的图正好是裁剪区域、没有多余留白。
   */
  setExportTransform(rect) {
    const canvas = this._canvas;
    const sx = canvas.width / rect.w;
    const sy = canvas.height / rect.h;
    this._applyTransform = (c) => {
      c.setTransform(sx, 0, 0, sy, -rect.x * sx, -rect.y * sy);
    };
  },

  /** 画布坐标 -> 图像坐标 */
  toImagePoint(x, y) {
    const k = this._fitScale * this._view.scale;
    return {
      x: this._imgW / 2 + (x - this._cw / 2 - this._view.tx) / k,
      y: this._imgH / 2 + (y - this._ch / 2 - this._view.ty) / k,
    };
  },

  /** 图像坐标 -> 裁剪框的 inline 样式（裁剪框是覆盖在画布上的普通视图，拖动时不用重绘 canvas） */
  cropStyleOf(rect) {
    if (!rect) return '';
    const k = this._fitScale * this._view.scale;
    const left = this._cw / 2 + this._view.tx + (rect.x - this._imgW / 2) * k;
    const top = this._ch / 2 + this._view.ty + (rect.y - this._imgH / 2) * k;
    return (
      'left:' + left.toFixed(1) + 'px;' +
      'top:' + top.toFixed(1) + 'px;' +
      'width:' + (rect.w * k).toFixed(1) + 'px;' +
      'height:' + (rect.h * k).toFixed(1) + 'px;'
    );
  },

  clampView() {
    const view = this._view;
    if (view.scale <= 1) {
      view.tx = 0;
      view.ty = 0;
      return;
    }
    const limitX = (this._cw * view.scale) / 2;
    const limitY = (this._ch * view.scale) / 2;
    view.tx = Math.max(-limitX, Math.min(limitX, view.tx));
    view.ty = Math.max(-limitY, Math.min(limitY, view.ty));
  },

  /* ==================== 绘制 ==================== */

  /** 整屏重绘（撤销、缩放、重置后调用） */
  renderAll() {
    if (!this._ctx || !this._base) return;
    this.setViewTransform();
    const ctx = this._ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this._canvas.width, this._canvas.height);
    this.paintScene(ctx);
  },

  /** 在给定变换下，把底图 + 所有操作画一遍 */
  paintScene(ctx) {
    ctx.save();
    this._applyTransform(ctx);
    ctx.globalCompositeOperation = 'source-over';
    ctx.drawImage(this._base, 0, 0, this._imgW, this._imgH);
    ctx.restore();

    this._ops.forEach((op) => {
      if (op.type === 'erase') this.paintErase(ctx, op);
      else if (op.type === 'brush') this.paintBrush(ctx, op);
    });
  },

  /** 橡皮擦：destination-out 直接擦掉像素 */
  paintErase(ctx, op) {
    ctx.save();
    this._applyTransform(ctx);
    ctx.globalCompositeOperation = 'destination-out';
    ctx.lineWidth = op.width;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = '#000';
    this.tracePath(ctx, op.points);
    ctx.restore();
  },

  /**
   * 画笔恢复：把原图在被涂到的区域画回来。
   * canvas 的 clip() 只能按「填充区域」裁剪、没法按描边裁剪，所以这里借一块临时画布：
   *   1) 把原图按当前变换画进临时层
   *   2) 用 destination-in + 描边路径做遮罩，只留下描边覆盖的部分
   *   3) 把临时层 source-over 贴回主画布（其它区域是透明的，不会影响已有内容）
   */
  paintBrush(ctx, op) {
    const scratch = this.getScratch();
    const sctx = scratch.getContext('2d');
    sctx.setTransform(1, 0, 0, 1, 0, 0);
    sctx.clearRect(0, 0, scratch.width, scratch.height);

    sctx.save();
    this._applyTransform(sctx);
    sctx.globalCompositeOperation = 'source-over';
    sctx.drawImage(this._base, 0, 0, this._imgW, this._imgH);
    sctx.restore();

    sctx.save();
    this._applyTransform(sctx);
    sctx.globalCompositeOperation = 'destination-in';
    sctx.lineWidth = op.width;
    sctx.lineCap = 'round';
    sctx.lineJoin = 'round';
    sctx.strokeStyle = '#000';
    sctx.fillStyle = '#000';
    this.tracePath(sctx, op.points);
    sctx.restore();

    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.globalCompositeOperation = 'source-over';
    ctx.drawImage(scratch, 0, 0);
    ctx.restore();
  },

  getScratch() {
    if (!this._scratch) {
      this._scratch = wx.createOffscreenCanvas({
        type: '2d',
        width: this._canvas.width,
        height: this._canvas.height,
      });
    }
    return this._scratch;
  },

  tracePath(ctx, points) {
    if (!points || !points.length) return;
    ctx.beginPath();
    if (points.length === 1) {
      // 单点：画一个圆点
      ctx.arc(points[0].x, points[0].y, Math.max(0.5, ctx.lineWidth / 2), 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    ctx.moveTo(points[0].x, points[0].y);
    for (let i = 1; i < points.length; i++) ctx.lineTo(points[i].x, points[i].y);
    ctx.stroke();
  },

  /* ==================== 触摸事件（由组件转发，坐标仍是画布坐标系） ==================== */

  touchesOf(e) {
    return (e && e.detail && e.detail.touches) || [];
  },

  onTouchStart(e) {
    const touches = this.touchesOf(e);

    // 双指：缩放/平移（任何模式下都可用）
    if (touches.length >= 2) {
      this.finishStroke();
      this._cropStart = null;
      this.startPinch(touches);
      return;
    }
    if (this._pinching || this._blockDraw) return;

    const t = touches[0];
    if (!t) return;
    const point = this.toImagePoint(t.x, t.y);

    if (this.data.mode === MODE.CROP) {
      this._cropStart = this.clampToImage(point);
      this.updateCropPreview(point);
      return;
    }

    // 笔刷的宽度按「屏幕上看起来的粗细」折算到图像坐标，这样缩放后手感一致
    const k = this._fitScale * this._view.scale;
    this._stroke = {
      type: this.data.mode === MODE.BRUSH ? 'brush' : 'erase',
      width: this.data.brushSize / k,
      points: [point],
    };
  },

  onTouchMove(e) {
    const touches = this.touchesOf(e);

    if (touches.length >= 2) {
      if (!this._pinch) this.startPinch(touches);
      else this.updatePinch(touches);
      return;
    }
    if (this._pinching || this._blockDraw) return;

    const t = touches[0];
    if (!t) return;
    const point = this.toImagePoint(t.x, t.y);

    if (this.data.mode === MODE.CROP) {
      if (this._cropStart) this.updateCropPreview(point);
      return;
    }

    if (!this._stroke) return;
    const points = this._stroke.points;
    const last = points[points.length - 1];
    // 抽稀：太近的点跳过，减少重绘与内存
    if (Math.abs(last.x - point.x) < 0.6 && Math.abs(last.y - point.y) < 0.6) return;
    points.push(point);
    this.drawSegment(last, point);
  },

  onTouchEnd(e) {
    const touches = this.touchesOf(e);

    if (touches.length === 0) {
      this._pinching = false;
      this._pinch = null;
      this._blockDraw = false;
      if (this.data.mode === MODE.CROP) this.finishCrop();
      else this.finishStroke();
      return;
    }

    // 还有手指留在屏幕上（一般是双指变单指），等全部抬起再恢复绘制，避免误画
    if (this._pinching) this._blockDraw = true;
  },

  /** 单段增量绘制：只在触摸点到的地方重绘，保证手感跟手 */
  drawSegment(from, to) {
    const op = { type: this._stroke.type, width: this._stroke.width, points: [from, to] };
    if (op.type === 'erase') this.paintErase(this._ctx, op);
    else this.paintBrush(this._ctx, op);
  },

  finishStroke() {
    if (!this._stroke) return;
    const stroke = this._stroke;
    this._stroke = null;
    if (!stroke.points.length) return;
    this.pushOp(stroke);
  },

  /* ==================== 双指缩放 ==================== */

  startPinch(touches) {
    this._pinching = true;
    this._pinch = {
      dist: this.touchDistance(touches),
      mid: this.touchMid(touches),
      view: { scale: this._view.scale, tx: this._view.tx, ty: this._view.ty },
    };
  },

  updatePinch(touches) {
    const pinch = this._pinch;
    if (!pinch) return;

    const dist = this.touchDistance(touches);
    const mid = this.touchMid(touches);
    const ratio = pinch.dist > 0 ? dist / pinch.dist : 1;
    const scale = Math.max(1, Math.min(MAX_ZOOM, pinch.view.scale * ratio));
    // 让捏合中点下的那个图像点保持不动（否则一放大就“跑偏”）
    const rx = scale / pinch.view.scale;
    const tx = mid.x - this._cw / 2 - rx * (pinch.mid.x - this._cw / 2 - pinch.view.tx);
    const ty = mid.y - this._ch / 2 - rx * (pinch.mid.y - this._ch / 2 - pinch.view.ty);

    this._view = { scale, tx, ty };
    this.clampView();
    this.renderAll();
    this.syncCropStyle();
  },

  touchDistance(touches) {
    const a = touches[0];
    const b = touches[1];
    return Math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  },

  touchMid(touches) {
    const a = touches[0];
    const b = touches[1];
    return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
  },

  /* ==================== 裁剪 ==================== */

  clampToImage(point) {
    return {
      x: Math.max(0, Math.min(this._imgW, point.x)),
      y: Math.max(0, Math.min(this._imgH, point.y)),
    };
  },

  updateCropPreview(current) {
    const start = this._cropStart;
    if (!start) return;
    const end = this.clampToImage(current);
    const rect = {
      x: Math.min(start.x, end.x),
      y: Math.min(start.y, end.y),
      w: Math.abs(end.x - start.x),
      h: Math.abs(end.y - start.y),
    };
    this._cropPreview = rect;
    this.setData({ cropStyle: this.cropStyleOf(rect) });
  },

  finishCrop() {
    const rect = this._cropPreview;
    this._cropStart = null;
    this._cropPreview = null;
    if (!rect) return;
    if (rect.w < MIN_CROP || rect.h < MIN_CROP) {
      // 太小当作误触，保留上一次的裁剪状态
      this.syncCropStyle();
      return;
    }
    this.pushOp({ type: 'crop', rect, prev: this.currentCropRect() });
    this.setData({ hasCrop: true });
    this.syncCropStyle();
  },

  /** 当前生效的裁剪区域 = ops 里最后一个裁剪操作（并夹紧到图片范围内） */
  currentCropRect() {
    for (let i = this._ops.length - 1; i >= 0; i--) {
      if (this._ops[i].type === 'crop') return this._ops[i].rect;
    }
    return null;
  },

  syncCropStyle() {
    const rect = this.currentCropRect();
    this.setData({
      cropStyle: rect ? this.cropStyleOf(rect) : '',
      hasCrop: !!rect,
    });
  },

  /* ==================== 顶部操作 ==================== */

  onModeTap(e) {
    const mode = e.currentTarget.dataset.mode;
    if (!mode || mode === this.data.mode) return;
    this.finishStroke();
    this._cropStart = null;
    this._cropPreview = null;
    this.setData({ mode, hint: MODE_HINT[mode] });
    this.syncCropStyle();
    this.renderAll();
  },

  onSizeTap(e) {
    const value = Number(e.currentTarget.dataset.value);
    if (value) this.setData({ brushSize: value });
  },

  pushOp(op) {
    this._ops.push(op);
    this.setData({ canUndo: true });
  },

  onUndo() {
    if (this._busy || !this._ops.length) return;
    const op = this._ops.pop();

    if (op.type === 'cutout') {
      // 云端抠图换了底图，撤销需要把上一张图重新载入
      this._basePath = op.prev;
      this.loadBase(op.prev)
        .then(() => {
          this.recalcFit();
          this._view = { scale: 1, tx: 0, ty: 0 };
          this.afterOpsChange();
        })
        .catch(() => wx.showToast({ title: '撤销失败', icon: 'none' }));
      return;
    }

    this.afterOpsChange();
  },

  afterOpsChange() {
    this.setData({ canUndo: this._ops.length > 0 });
    this.syncCropStyle();
    this.renderAll();
  },

  onReset() {
    if (this._busy) return;
    if (!this._ops.length) {
      wx.showToast({ title: '还没有可重置的操作', icon: 'none' });
      return;
    }
    wx.showModal({
      title: '重置',
      content: '会清空本次的涂抹与裁剪，回到最初的原图（抠图结果也会一并撤销）。',
      confirmText: '重置',
      success: (res) => {
        if (res.confirm) this.resetAll();
      },
    });
  },

  resetAll() {
    this._ops = [];
    this._basePath = this.data.srcPath;
    this.setData({ canUndo: false, hasCrop: false, cropStyle: '', loading: true });
    this.loadBase(this.data.srcPath)
      .then(() => {
        this.recalcFit();
        this._view = { scale: 1, tx: 0, ty: 0 };
        this.setData({ loading: false });
        this.renderAll();
      })
      .catch(() => {
        this.setData({ loading: false });
        wx.showToast({ title: '重置失败', icon: 'none' });
      });
  },

  onCloudCutout() {
    if (this._busy) return;
    const basePath = this._basePath || this.data.srcPath;
    if (!basePath) {
      wx.showToast({ title: '没有可处理的图片', icon: 'none' });
      return;
    }

    this._busy = true;
    wx.showLoading({ title: '抠图中…', mask: true });

    cutout
      .cutout(basePath)
      .then((res) => {
        wx.hideLoading();
        this._busy = false;

        // 没配接口时 utils/cutout.js 会返回原图，这里明确提示，引导用户手动处理
        if (!res.cloud) {
          wx.showModal({
            title: '云端抠图未配置',
            content:
              res.message +
              '\n\n可以先用橡皮擦手动擦掉背景；要启用云端抠图，把 utils/cutout.js 顶部的 apiUrl / apiKey 换成你自己的接口即可。',
            showCancel: false,
            confirmText: '知道了',
          });
          return;
        }

        const prev = this._basePath;
        return this.loadBase(res.path).then(() => {
          this._basePath = res.path;
          this.pushOp({ type: 'cutout', prev });
          this.recalcFit();
          this._view = { scale: 1, tx: 0, ty: 0 };
          this.afterOpsChange();
          wx.showToast({ title: '抠图完成', icon: 'success' });
        });
      })
      .catch((err) => {
        wx.hideLoading();
        this._busy = false;
        console.error('[image-editor] 云端抠图失败', err);
        wx.showToast({ title: (err && err.message) || '抠图失败', icon: 'none' });
      });
  },

  /* ==================== 导出 / 取消 ==================== */

  onConfirm() {
    if (this._exporting || this._busy || !this._base) return;

    const rect = this.currentCropRect() || { x: 0, y: 0, w: this._imgW, h: this._imgH };
    const longSide = Math.max(rect.w, rect.h);
    const ratio = longSide > EXPORT_MAX_SIDE ? EXPORT_MAX_SIDE / longSide : 1;
    const destWidth = Math.max(1, Math.round(rect.w * ratio));
    const destHeight = Math.max(1, Math.round(rect.h * ratio));

    this._exporting = true;
    wx.showLoading({ title: '生成中…', mask: true });

    // 导出前把画布切成「裁剪区域铺满」的状态，导出的像素里就不会有周围留白
    this.setExportTransform(rect);
    const ctx = this._ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this._canvas.width, this._canvas.height);
    this.paintScene(ctx);

    this._comp
      .exportToTempFile({
        x: 0,
        y: 0,
        width: this._cw,
        height: this._ch,
        destWidth,
        destHeight,
        fileType: 'png', // 擦掉的地方要保留透明通道，必须用 png
      })
      .then((tempFilePath) => {
        this.finishExport();
        this.emitResult('done', {
          path: tempFilePath,
          originalPath: this.data.srcPath,
          crop: rect,
        });
        wx.navigateBack();
      })
      .catch((err) => {
        console.error('[image-editor] 导出失败', err);
        this.finishExport();
        wx.showToast({ title: '生成图片失败', icon: 'none' });
      });
  },

  finishExport() {
    this._exporting = false;
    wx.hideLoading();
    this.renderAll(); // 恢复查看状态
  },

  onCancel() {
    this.emitResult('cancel', {});
    wx.navigateBack();
  },

  emitResult(event, payload) {
    if (typeof this.getOpenerEventChannel !== 'function') return;
    const channel = this.getOpenerEventChannel();
    if (channel && typeof channel.emit === 'function') channel.emit(event, payload);
  },
});
