/**
 * components/image-canvas —— canvas 2D 容器（图片编辑器 / 试衣间共用）
 *
 * 组件只做画布相关的“脏活”，画什么完全由使用方决定：
 *  - 取节点并按 dpr 设置像素尺寸（统一走 canvas 2D，不用旧版 createCanvasContext）
 *  - createImage(path)：加载图片，交给使用方 drawImage
 *  - exportToTempFile(options)：封装 wx.canvasToTempFilePath，返回临时文件路径
 *  - interactive 打开时，把画布上的触摸事件转发给页面，坐标保持「画布坐标系」，
 *    这样手势逻辑（涂抹、捏合缩放）仍然写在页面里，坐标语义和直接写 canvas 时一致
 *
 * 使用方式：
 *   <image-canvas id="editor" class="xxx" interactive bind:touchstart="onTouchStart" ... />
 *   const comp = this.selectComponent('#editor');
 *   comp.whenReady().then(({ canvas, ctx, dpr, width, height }) => { ... });
 *
 * 布局说明：画布的 CSS 尺寸由使用方决定（组件内部 100% 撑满），导出时的
 * x/y/width/height 用 CSS 像素、destWidth/destHeight 用像素，和直接调 canvasToTempFilePath 一致。
 */

Component({
  properties: {
    // 是否需要把触摸事件转发给页面（交互式画布，例如图片编辑器）
    interactive: {
      type: Boolean,
      value: false,
    },
  },

  data: {
    ready: false,
  },

  lifetimes: {
    created() {
      this._metrics = null;
      this._readyPromise = new Promise((resolve, reject) => {
        this._resolveReady = resolve;
        this._rejectReady = reject;
      });
      // 使用方可能不关心失败原因，这里先挂一个空 catch，避免出现未处理的 Promise 拒绝
      this._readyPromise.catch(() => {});
    },

    ready() {
      this.initCanvas();
    },
  },

  methods: {
    /* ==================== 初始化 ==================== */

    initCanvas() {
      this.createSelectorQuery()
        .select('#canvas')
        .fields({ node: true, size: true })
        .exec((res) => {
          const info = res && res[0];
          if (!info || !info.node) {
            this._rejectReady(new Error('canvas 节点获取失败'));
            this.triggerEvent('error');
            return;
          }

          const dpr = this.pixelRatio();
          const canvas = info.node;
          canvas.width = Math.round(info.width * dpr);
          canvas.height = Math.round(info.height * dpr);

          this._metrics = {
            canvas,
            ctx: canvas.getContext('2d'),
            dpr,
            width: info.width,
            height: info.height,
          };
          this.setData({ ready: true });
          this._resolveReady(this._metrics);
          this.triggerEvent('ready', {
            width: info.width,
            height: info.height,
            dpr,
          });
        });
    },

    pixelRatio() {
      try {
        if (wx.getWindowInfo) return wx.getWindowInfo().pixelRatio || 2;
        return wx.getSystemInfoSync().pixelRatio || 2;
      } catch (err) {
        return 2;
      }
    },

    /** 画布就绪后 resolve，参数就是 getMetrics() 的内容 */
    whenReady() {
      return this._readyPromise;
    },

    /** { canvas, ctx, dpr, width, height }；未就绪时返回 null */
    getMetrics() {
      return this._metrics;
    },

    getCanvas() {
      return this._metrics ? this._metrics.canvas : null;
    },

    getContext() {
      return this._metrics ? this._metrics.ctx : null;
    },

    /* ==================== 图片与导出 ==================== */

    /** 加载图片（canvas.createImage），失败时 reject */
    createImage(path) {
      return new Promise((resolve, reject) => {
        const canvas = this.getCanvas();
        if (!canvas || !path) {
          reject(new Error('缺少图片路径或画布未就绪'));
          return;
        }
        const img = canvas.createImage();
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error('图片加载失败：' + path));
        img.src = path;
      });
    },

    /** 清空整块画布 */
    clear() {
      const m = this._metrics;
      if (!m) return;
      m.ctx.setTransform(1, 0, 0, 1, 0, 0);
      m.ctx.clearRect(0, 0, m.canvas.width, m.canvas.height);
    },

    /**
     * 导出临时文件
     * @param {{x?:number, y?:number, width?:number, height?:number, destWidth?:number, destHeight?:number, fileType?:string, quality?:number}} options
     *        x/y/width/height 不传时交给接口自己取整块画布（默认值就是整块画布，不依赖坐标单位）
     *        destWidth/destHeight 不传时按画布实际像素导出，即不缩放
     * @returns {Promise<string>} 临时文件路径
     */
    exportToTempFile(options) {
      const m = this._metrics;
      const opts = options || {};
      return new Promise((resolve, reject) => {
        if (!m) {
          reject(new Error('画布还没准备好'));
          return;
        }

        const params = {
          canvas: m.canvas,
          destWidth: opts.destWidth || m.canvas.width,
          destHeight: opts.destHeight || m.canvas.height,
          fileType: opts.fileType || 'png',
          quality: opts.quality,
          success: (res) => resolve(res.tempFilePath),
          fail: (err) => reject(err),
        };
        // 显式传了就带上，没传就让接口用默认的「整块画布」
        if (typeof opts.x === 'number') params.x = opts.x;
        if (typeof opts.y === 'number') params.y = opts.y;
        if (typeof opts.width === 'number') params.width = opts.width;
        if (typeof opts.height === 'number') params.height = opts.height;

        wx.canvasToTempFilePath(params);
      });
    },

    /* ==================== 触摸转发 ==================== */

    onTouchStart(e) {
      this.forward('touchstart', e);
    },

    onTouchMove(e) {
      this.forward('touchmove', e);
    },

    onTouchEnd(e) {
      this.forward('touchend', e);
    },

    /**
     * 把 touch 对象里的坐标原样带出去（touches 在 canvas 上触发时，x/y 就是画布坐标系）。
     * 只转必要的字段，避免每帧序列化一大堆用不到的数据。
     */
    forward(name, e) {
      if (!this.data.interactive) return;
      this.triggerEvent(name, {
        touches: pickTouches(e.touches),
        changedTouches: pickTouches(e.changedTouches),
      });
    },
  },
});

function pickTouches(list) {
  return (list || []).map((t) => ({
    identifier: t.identifier,
    x: t.x,
    y: t.y,
    pageX: t.pageX,
    pageY: t.pageY,
  }));
}
