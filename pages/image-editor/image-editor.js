/**
 * pages/image-editor —— 抠图 / 图片编辑
 *
 * 进入方式（调用方约定）：/pages/image-editor/image-editor?src=<encodeURIComponent 后的图片路径>
 * 回传方式：this.getOpenerEventChannel().emit('done', { path, originalPath, crop })
 *          path 是 canvas 导出的临时文件路径（PNG，带透明通道），由调用方负责落盘；
 *          crop 恒为整幅画面（裁剪在编辑时就生效了），保留这个字段只是为了兼容现有调用方
 *
 * 坐标系约定（这一页最容易出错的地方，统一在这里说清楚）：
 *   - 画布坐标系：canvas 元素的 CSS 像素，原点在左上角。触摸事件的 x/y 就是这个坐标系。
 *   - 图像坐标系：原图自身的像素坐标，原点在图片左上角。
 *   - 笔画、裁剪框一律用「图像坐标」记录，所以缩放/平移之后重绘、导出都不会错位。
 *
 * 渲染方式：所有内容都在「图像坐标系」里描述，绘制前统一套一次变换（_applyTransform）：
 *   - 查看模式：dpr 变换 + 居中 + fitScale × 手势缩放 + 平移
 *   - 导出模式：把要导出的区域拉伸铺满画布，导出时再按比例还原（这样导出的图没有多余留白）
 * 撤销 / 重做：ops 栈记录每一次操作（擦除/画笔是路径点，裁剪与云端抠图是「换底图」），
 *      撤销 = 弹出栈顶后整体重绘，重做 = 从 _redo 栈放回去，逻辑简单且不会累积误差。
 *
 * 裁剪是「即刻生效」的：松手就把框内画面（含已经擦/补过的部分）渲染成一张新底图，之后所有操作
 * 都在新底图上进行 —— 用户裁剪后通常还要继续用橡皮擦抠细节，坐标与缩放手感基于裁剪后的画面才直观。
 * 代价是每裁一次会重编码一次（长边限制在 EXPORT_MAX_SIDE，不会越裁越大），
 * 所以裁剪这个操作里完整存了「旧底图 + 旧笔画栈 + 旧取景范围」三样，撤销就能整体回滚。
 *
 * 手动擦除要真能用，靠三件事（缺一个用户就会觉得「擦了没反应」）：
 *   1) 舞台默认铺透明棋盘格：白底照 + 白底舞台，擦完和没擦长得一模一样（白底预览见 .stage--plain）
 *   2) 画笔恢复取自最初的原图 _src：云端抠图抠多了、抠少了都能手动补回来
 *      （_srcRect 记着当前底图对应原图的哪一块，裁剪之后涂回原图内容依然对得上）
 *   3) 笔刷粗细按屏幕上看到的尺寸折算到图像坐标，缩放后手感一致；
 *      粗细由一个 slider 无级调节（BRUSH_MIN ~ BRUSH_MAX 屏幕像素），
 *      拖动中只更新显示数值（避免写回 slider.value 导致抖动），实际值存在 _brush 里立即生效
 *
 * 画布相关的事（取节点、按 dpr 定尺寸、加载图片、导出临时文件、触摸事件转发）都交给
 * components/image-canvas，这一页只负责「画什么」和手势语义。
 */
const cutout = require('../../utils/cutout.js');

const MODE = { ERASE: 'erase', BRUSH: 'brush', CROP: 'crop' };
// 笔刷粗细：无级调节，单位是「屏幕像素」（折算到图像坐标后缩放时手感才一致）
const BRUSH_MIN = 4;
const BRUSH_MAX = 112; // 最粗的档位：大区块擦除时不用来回涂
const BRUSH_DEFAULT = 18;
const MAX_ZOOM = 8; // 相对于「适应屏幕」的最大放大倍数
const MIN_CROP = 24; // 裁剪框最小边长（图像坐标）
const MIN_CROP_SCREEN = 20; // 裁剪框在屏幕上最小能有多大（屏幕像素），低于这个当手滑
const EXPORT_MAX_SIDE = 1600; // 导出长边上限，控制文件体积

const MODE_HINT = {
  [MODE.ERASE]: '手指涂抹擦掉背景，双指捏合可放大细修',
  [MODE.BRUSH]: '涂回擦掉/抠掉的部分（取自原图），双指捏合可放大细修',
  [MODE.CROP]: '拖动框选要保留的区域，松手立刻裁剪（不满意点撤销）',
};

Page({
  data: {
    mode: MODE.ERASE,
    brushSize: BRUSH_DEFAULT, // 给 slider 的绑定值（只在拖动结束时写回，避免拖动中来回抖动）
    brushText: String(BRUSH_DEFAULT), // 拖动过程中实时显示的数字
    brushMin: BRUSH_MIN,
    brushMax: BRUSH_MAX,
    canUndo: false,
    canRedo: false,
    bgPlain: true, // 白底预览；擦过一笔或抠过图之后会自动切成棋盘格
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
    this._redo = [];
    this._brush = BRUSH_DEFAULT; // 实际生效的笔刷粗细（拖动过程中就立即生效）
    this._view = { scale: 1, tx: 0, ty: 0 };
    this._basePath = src;
    this._src = null; // 最初的原图，画笔恢复的取色来源（云端抠图换掉 _base 后仍然留着）
    this._srcRect = null; // 当前底图对应原图里的哪一块（裁剪后跟着变，画笔恢复按它取色）
    this._stroke = null;
    this._cropStart = null;
    this._cropPreview = null;
    this._pinching = false;
    this._pinch = null;
    this._blockDraw = false;
    this._busy = false;
    this._exporting = false;
    this._bgTouched = false; // 用户手动切过底色之后，就不自动切了

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
        this._src = this._base; // 后面云端抠图会换掉 _base，原图必须留一份给画笔恢复
        this._srcRect = this.fullSrcRect();
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

  /** 原图整幅的取景范围（未裁剪时的 _srcRect 就是这个） */
  fullSrcRect() {
    const src = this._src || this._base;
    return { x: 0, y: 0, w: (src && src.width) || 1, h: (src && src.height) || 1 };
  },

  /** 当前底图对应原图里的哪一块：画笔恢复按这块取色，所以裁剪之后要对得上 */
  sourceBox() {
    return this._srcRect || this.fullSrcRect();
  },

  /** 在图像坐标里裁 rect 之后，新的取景范围（按当前底图与原图的比例等比换算） */
  cropSrcRect(rect) {
    const box = this.sourceBox();
    const sx = this._imgW ? box.w / this._imgW : 1;
    const sy = this._imgH ? box.h / this._imgH : 1;
    return {
      x: box.x + rect.x * sx,
      y: box.y + rect.y * sy,
      w: Math.max(1, rect.w * sx),
      h: Math.max(1, rect.h * sy),
    };
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
   * 注意取的是 _src（最初的原图）而不是 _base：云端抠图之后 _base 已经是抠好的透明图，
   * 拿它当取色来源就「刷不回」被 AI 抠掉的部分了。
   *
   * canvas 的 clip() 只能按「填充区域」裁剪、没法按描边裁剪，所以这里借一块临时画布：
   *   1) 把原图按当前变换画进临时层
   *   2) 用 destination-in + 描边路径做遮罩，只留下描边覆盖的部分
   *   3) 把临时层 source-over 贴回主画布（其它区域是透明的，不会影响已有内容）
   */
  paintBrush(ctx, op) {
    const scratch = this.getScratch();
    const sctx = scratch.getContext('2d');
    const source = this._src || this._base;
    sctx.setTransform(1, 0, 0, 1, 0, 0);
    sctx.clearRect(0, 0, scratch.width, scratch.height);

    sctx.save();
    this._applyTransform(sctx);
    sctx.globalCompositeOperation = 'source-over';
    // 按取景范围取色、显式给目标宽高：原图与抠图结果的像素尺寸可能不一致（部分接口只返回
    // 低分辨率预览图），裁剪之后取景范围也跟着裁过，所以涂回的内容依然和底图对齐
    const box = this._src ? this.sourceBox() : this.fullSrcRect();
    sctx.drawImage(source, box.x, box.y, box.w, box.h, 0, 0, this._imgW, this._imgH);
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
      // 框选到一半又搭上第二根手指：取消这次框选，别拿半个框去裁剪
      if (this._cropStart || this._cropPreview) {
        this._cropStart = null;
        this._cropPreview = null;
        this.setData({ cropStyle: '' });
      }
      this.startPinch(touches);
      return;
    }
    if (this._pinching || this._blockDraw) return;
    // 抠图 / 裁剪正在处理时别让新笔画混进来（底图马上要换，画了也会被丢掉）
    if (this._busy) return;

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
      width: this.currentBrush() / k,
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
    this.setData({ cropStyle: '' });
    if (!rect) return;
    // 裁剪立刻生效，误触的代价比从前大，所以两个角度都拦一下：
    // 图像坐标下别太小（不然导出的是个渣），屏幕上看着也别太小（不然是手滑）
    const k = this._fitScale * this._view.scale;
    if (rect.w < MIN_CROP || rect.h < MIN_CROP || rect.w * k < MIN_CROP_SCREEN || rect.h * k < MIN_CROP_SCREEN) {
      wx.showToast({ title: '框太小了，再拖大一点', icon: 'none' });
      return;
    }
    this.applyCrop(rect);
  },

  /**
   * 裁剪即刻生效：把框内的画面（含已擦 / 已补的部分）渲染成一张新底图，之后一切操作都基于它。
   * 之所以「烘」成图片而不是留个矩形到最后再导，是因为裁剪完通常还要继续用橡皮擦抠细节，
   * 那时候坐标与缩放手感都基于裁剪后的画面才直观。
   * 撤销需要把旧底图、旧笔画栈、旧取景范围一起还原，所以这一份状态原样存进 op 里。
   */
  applyCrop(rect) {
    if (this._busy || !this._base) return;
    this._busy = true;
    wx.showLoading({ title: '裁剪中…', mask: true });

    const prev = {
      path: this._basePath,
      img: this._base,
      src: this._src,
      srcRect: this._srcRect,
      ops: this._ops.slice(),
    };
    const op = { type: 'crop', rect, prev, next: null };

    this.renderRegionToFile(rect)
      .then((path) =>
        this._comp.createImage(path).then((img) => {
          // 新底图 + 它的取景范围；创建好再切，失败了画面还是原来的样子
          op.next = { path, img, srcRect: this.cropSrcRect(rect) };
          return img;
        })
      )
      .then(() => {
        this._busy = false;
        this._redo = [];
        // 画面已经烘进底图：笔画栈清空，只留这次裁剪操作本身，撤销时整体回滚
        this._ops = [op];
        this.useBase(op.next);
        // 裁完就能继续抠细节，所以直接切回橡皮擦
        this.setData({ mode: MODE.ERASE, hint: MODE_HINT[MODE.ERASE] });
        wx.hideLoading();
        wx.showToast({ title: '已裁剪，可撤销', icon: 'none' });
      })
      .catch((err) => {
        this._busy = false;
        wx.hideLoading();
        this.renderAll();
        console.error('[image-editor] 裁剪失败', err);
        wx.showToast({ title: '裁剪失败，请重试', icon: 'none' });
      });
  },

  /** 切到某个底图状态（裁剪撤销 / 重做都走这里）：底图、取景范围、笔画栈一起换 */
  useBase(state) {
    this._basePath = state.path;
    this._base = state.img;
    this._imgW = state.img.width;
    this._imgH = state.img.height;
    if (state.src) this._src = state.src;
    this._srcRect = state.srcRect || this.fullSrcRect();
    if (state.ops) this._ops = state.ops.slice();
    this.recalcFit();
    this._view = { scale: 1, tx: 0, ty: 0 };
    this.afterOpsChange();
  },

  /**
   * 把图像坐标系里的某块区域渲染成一张临时 PNG（裁剪与导出都走它）。
   * 渲染时画布会切到「导出变换」，结束后恢复成正常的查看状态。
   */
  renderRegionToFile(rect) {
    const longSide = Math.max(rect.w, rect.h);
    const ratio = longSide > EXPORT_MAX_SIDE ? EXPORT_MAX_SIDE / longSide : 1;
    const destWidth = Math.max(1, Math.round(rect.w * ratio));
    const destHeight = Math.max(1, Math.round(rect.h * ratio));

    this.setExportTransform(rect);
    const ctx = this._ctx;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this._canvas.width, this._canvas.height);
    this.paintScene(ctx);

    return this._comp
      .exportToTempFile({
        x: 0,
        y: 0,
        width: this._cw,
        height: this._ch,
        destWidth,
        destHeight,
        fileType: 'png', // 擦掉的地方要保留透明通道，必须用 png
      })
      .then((path) => {
        this.renderAll(); // 恢复查看状态
        return path;
      });
  },

  /* ==================== 顶部操作 ==================== */

  onModeTap(e) {
    const mode = e.currentTarget.dataset.mode;
    if (!mode || mode === this.data.mode) return;
    this.finishStroke();
    this._cropStart = null;
    this._cropPreview = null;
    this.setData({ mode, hint: MODE_HINT[mode], cropStyle: '' });
    this.renderAll();
  },

  /** 当前笔刷粗细（屏幕像素）：以内部值为准，比 data 更及时 */
  currentBrush() {
    return this._brush || this.data.brushSize;
  },

  clampBrush(raw) {
    const n = Math.round(Number(raw));
    if (isNaN(n)) return this.currentBrush();
    return Math.max(BRUSH_MIN, Math.min(BRUSH_MAX, n));
  },

  /**
   * 拖动中：立即生效 + 更新数字显示，但不写回 slider 的 value。
   * 写回 value 会让 slider 被 setData 的旧值往回拽，手指快时能明显看到抖动。
   */
  onBrushChanging(e) {
    const value = this.clampBrush(e.detail.value);
    this._brush = value;
    const text = String(value);
    if (this.data.brushText !== text) this.setData({ brushText: text });
  },

  /** 松手：把最终值写回 data，slider 与内部值重新对齐 */
  onBrushChange(e) {
    const value = this.clampBrush(e.detail.value);
    this._brush = value;
    this.setData({ brushSize: value, brushText: String(value) });
  },

  pushOp(op) {
    this._ops.push(op);
    this._redo = []; // 记录新操作后，原来的重做链就失效了

    const patch = { canUndo: true, canRedo: false };
    // 第一次擦/抠的时候自动切到棋盘格：白底照上不切，用户根本看不出擦掉了哪里
    if (
      !this._bgTouched &&
      this.data.bgPlain &&
      (op.type === 'erase' || op.type === 'brush' || op.type === 'cutout')
    ) {
      patch.bgPlain = false;
    }
    this.setData(patch);
  },

  onUndo() {
    if (this._busy || !this._ops.length) return;
    const op = this._ops.pop();
    this._redo.push(op);

    if (op.type === 'crop') {
      // 裁剪把画面烘进了底图：撤销 = 换回旧底图 + 旧笔画栈 + 旧取景范围
      this.useBase(op.prev);
      return;
    }

    if (op.type === 'cutout') {
      // 云端抠图换了底图，撤销需要把上一张图重新载入
      this._basePath = op.prev;
      this.loadBase(op.prev)
        .then(() => {
          this.recalcFit();
          this._view = { scale: 1, tx: 0, ty: 0 };
          this.afterOpsChange();
        })
        .catch(() => {
          this._redo.pop();
          wx.showToast({ title: '撤销失败', icon: 'none' });
        });
      return;
    }

    this.afterOpsChange();
  },

  onRedo() {
    if (this._busy || !this._redo.length) return;
    const op = this._redo.pop();

    if (op.type === 'crop') {
      // 重做裁剪：换回裁剪后的底图，并把这次裁剪重新放回操作栈（这样还能再撤销）
      this._ops = [op];
      this.useBase(op.next);
      return;
    }

    if (op.type === 'cutout') {
      // 重做云端抠图：把 op.next 那张抠图结果重新载入
      this._basePath = op.next;
      this.loadBase(op.next)
        .then(() => {
          this._ops.push(op);
          this.recalcFit();
          this._view = { scale: 1, tx: 0, ty: 0 };
          this.afterOpsChange();
        })
        .catch(() => {
          this._redo.push(op);
          wx.showToast({ title: '重做失败', icon: 'none' });
        });
      return;
    }

    this._ops.push(op);
    this.afterOpsChange();
  },

  /** 白底 / 棋盘格切换：白底看抠图边缘更接近实物，棋盘格看透明区域更清楚 */
  onToggleBg() {
    this._bgTouched = true;
    const bgPlain = !this.data.bgPlain;
    this.setData({ bgPlain });
    wx.showToast({ title: bgPlain ? '已切到白底' : '已切到棋盘格', icon: 'none' });
  },

  afterOpsChange() {
    this.setData({
      canUndo: this._ops.length > 0,
      canRedo: this._redo.length > 0,
    });
    this.renderAll();
  },

  onReset() {
    if (this._busy) return;
    if (!this._ops.length && !this._redo.length) {
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
    this._redo = [];
    this._basePath = this.data.srcPath;
    this.setData({
      canUndo: false,
      canRedo: false,
      cropStyle: '',
      loading: true,
    });
    this.loadBase(this.data.srcPath)
      .then(() => {
        this._src = this._base; // 回到最初的原图，画笔恢复的来源也跟着复位
        this._srcRect = this.fullSrcRect();
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
          // next 是给「重做」用的：重做云端抠图要能重新载入这张结果图
          this.pushOp({ type: 'cutout', prev, next: res.path });
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

    this._exporting = true;
    wx.showLoading({ title: '生成中…', mask: true });

    // 裁剪已经在编辑过程中生效了，这里把当前整幅画面导出去就行
    const rect = { x: 0, y: 0, w: this._imgW, h: this._imgH };
    this.renderRegionToFile(rect)
      .then((tempFilePath) => {
        this._exporting = false;
        wx.hideLoading();
        this.emitResult('done', {
          path: tempFilePath,
          originalPath: this.data.srcPath,
          crop: rect,
        });
        wx.navigateBack();
      })
      .catch((err) => {
        console.error('[image-editor] 导出失败', err);
        this._exporting = false;
        wx.hideLoading();
        this.renderAll();
        wx.showToast({ title: '生成图片失败', icon: 'none' });
      });
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
