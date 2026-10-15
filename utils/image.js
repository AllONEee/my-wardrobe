/**
 * utils/image.js —— 图片：选图 / 压缩 / 本地文件系统读写
 *
 * 存储约定：
 *  - 用户数据目录：wx.env.USER_DATA_PATH/images/（小程序自己的沙箱目录，不会被系统清理）
 *  - 临时文件（wx.chooseMedia / canvas 导出）只在小程序本次运行期间有效，需要长期保存的必须 copyFile 进来
 *  - storage 里只存路径字符串，不存 base64
 *
 * 压缩注意：
 *  - 抠图结果是带透明通道的 PNG，wx.compressImage 在部分机型会把 PNG 转成 JPEG 从而丢掉透明背景，
 *    所以默认策略是「只压 JPG/JPEG，PNG 原样保存」（compress 参数传 'auto'）。
 */

let fs = null;

function getFs() {
  if (!fs) fs = wx.getFileSystemManager();
  return fs;
}

function userDataPath() {
  return (wx.env && wx.env.USER_DATA_PATH) || '';
}

function imageDir() {
  return userDataPath() + '/images';
}

/** 确保目录存在（mkdirSync 的 recursive 参数需要基础库 2.3.0+） */
function ensureDir(dir) {
  const target = dir || imageDir();
  const manager = getFs();
  try {
    manager.accessSync(target);
    return true;
  } catch (err) {
    // 目录不存在，继续创建
  }
  try {
    manager.mkdirSync(target, true);
    return true;
  } catch (err) {
    try {
      manager.mkdirSync(target);
      return true;
    } catch (err2) {
      console.error('[image] 创建目录失败：', target, err2);
      return false;
    }
  }
}

function extOf(path, fallback) {
  const match = /\.([a-zA-Z0-9]+)(?:\?|$)/.exec(path || '');
  return match ? '.' + match[1].toLowerCase() : fallback || '.jpg';
}

function isPng(path) {
  return extOf(path, '').indexOf('png') >= 0;
}

function uniqueName(prefix, ext) {
  return (
    (prefix || 'img') +
    '_' +
    Date.now() +
    '_' +
    Math.floor(Math.random() * 10000) +
    (ext || '.jpg')
  );
}

/** 用户取消选图/授权时会走 fail，用这个判断，页面里直接 return 即可 */
function isCancel(err) {
  const msg = (err && (err.errMsg || err.message)) || '';
  return msg.indexOf('cancel') >= 0;
}

/* ==================== 选图 ==================== */

/**
 * 选择图片
 * @param {{count?: number, sourceType?: string[]}} options
 * @returns {Promise<string[]>} 临时文件路径数组
 */
function chooseImage(options) {
  const opts = options || {};
  const count = opts.count || 1;
  const sourceType = opts.sourceType || ['album', 'camera'];

  return new Promise((resolve, reject) => {
    if (wx.chooseMedia) {
      wx.chooseMedia({
        count,
        mediaType: ['image'],
        sourceType,
        sizeType: ['original', 'compressed'],
        camera: 'back',
        success(res) {
          const paths = (res.tempFiles || []).map((f) => f.tempFilePath).filter(Boolean);
          paths.length ? resolve(paths) : reject(new Error('没有选到图片'));
        },
        fail: reject,
      });
      return;
    }

    if (wx.chooseImage) {
      wx.chooseImage({
        count,
        sourceType,
        sizeType: ['original', 'compressed'],
        success(res) {
          const paths = (res.tempFilePaths || []).filter(Boolean);
          paths.length ? resolve(paths) : reject(new Error('没有选到图片'));
        },
        fail: reject,
      });
      return;
    }

    reject(new Error('当前基础库不支持选图，请升级到 2.30.0 以上'));
  });
}

/* ==================== 压缩 ==================== */

/**
 * 压缩图片
 * @param {string} path
 * @param {{quality?: number, force?: boolean}} options force = true 时对 PNG 也压缩
 * @returns {Promise<string>} 压缩后的临时路径（失败时回退原路径，不打断业务流程）
 */
function compress(path, options) {
  const opts = options || {};
  const quality = opts.quality || 80;

  // 带透明通道的 PNG 默认不压缩，避免透明背景被转成黑/白底
  if (!opts.force && isPng(path)) {
    return Promise.resolve(path);
  }
  if (!wx.compressImage) {
    return Promise.resolve(path);
  }

  return new Promise((resolve) => {
    wx.compressImage({
      src: path,
      quality,
      success(res) {
        resolve(res.tempFilePath || path);
      },
      fail(err) {
        console.warn('[image] 压缩失败，使用原图：', err);
        resolve(path);
      },
    });
  });
}

function getImageInfo(path) {
  return new Promise((resolve, reject) => {
    wx.getImageInfo({
      src: path,
      success(res) {
        resolve({
          path: res.path || path,
          width: res.width,
          height: res.height,
          orientation: res.orientation,
          type: res.type,
        });
      },
      fail: reject,
    });
  });
}

/* ==================== 保存到本地文件系统 ==================== */

/**
 * 把一个（临时的）图片文件保存到用户数据目录
 * @param {string} tempPath 临时文件路径
 * @param {{prefix?: string, compress?: 'auto'|boolean, quality?: number}} options
 * @returns {Promise<{path: string, width: number, height: number}>}
 */
function saveImage(tempPath, options) {
  const opts = options || {};
  const prefix = opts.prefix || 'img';
  const shouldCompress = opts.compress === undefined ? 'auto' : opts.compress;

  return compress(tempPath, { quality: opts.quality, force: shouldCompress === true })
    .then((compressedPath) => {
      const infoPromise = getImageInfo(compressedPath).catch(() => ({
        path: compressedPath,
        width: 0,
        height: 0,
      }));
      return infoPromise.then((info) => ({ compressedPath, info }));
    })
    .then(({ compressedPath, info }) => {
      if (!ensureDir()) throw new Error('无法创建图片目录');
      const ext = extOf(compressedPath, '.jpg');
      const dest = imageDir() + '/' + uniqueName(prefix, ext);
      getFs().copyFileSync(compressedPath, dest);
      return { path: dest, width: info.width, height: info.height };
    });
}

/**
 * 把 base64 图片（云端抠图返回的 PNG）写入本地文件系统
 * @param {string} base64 允许带 'data:image/png;base64,' 前缀
 */
function saveBase64(base64, options) {
  const opts = options || {};
  return new Promise((resolve, reject) => {
    try {
      const raw = String(base64 || '').replace(/^data:image\/\w+;base64,/, '');
      if (!raw) {
        reject(new Error('base64 内容为空'));
        return;
      }
      if (!ensureDir()) {
        reject(new Error('无法创建图片目录'));
        return;
      }
      const ext = opts.ext || '.png';
      const dest = imageDir() + '/' + uniqueName(opts.prefix || 'cut', ext);
      getFs().writeFileSync(dest, raw, 'base64');
      resolve(dest);
    } catch (err) {
      reject(err);
    }
  });
}

/** 读取文件为 base64（云端抠图走 JSON body 时用） */
function toBase64(path) {
  return new Promise((resolve, reject) => {
    try {
      const data = getFs().readFileSync(path, 'base64');
      resolve(data);
    } catch (err) {
      reject(err);
    }
  });
}

/* ==================== 删除 ==================== */

/** 是否是我们自己沙箱目录下的图片（选择器 / canvas 出来的临时路径都算「不是」） */
function isOwned(path) {
  return !!path && String(path).indexOf(imageDir()) === 0;
}

/** 只删除我们自己沙箱里的图片，临时路径一律忽略（避免误删系统临时文件） */
function removeFile(path) {
  if (!isOwned(path)) return false;
  try {
    getFs().unlinkSync(path);
    return true;
  } catch (err) {
    console.warn('[image] 删除失败：', path, err);
    return false;
  }
}

function removeFiles(paths) {
  (paths || []).forEach(removeFile);
}

/** 清空所有已保存的图片（设置页「清空数据」用） */
function clearImages() {
  const target = imageDir();
  try {
    getFs().rmdirSync(target, true);
  } catch (err) {
    // 目录本来就不存在时会失败，忽略
  }
  return ensureDir();
}

/** 已保存图片的数量与总大小（KB），设置页展示用 */
function getImagesStat() {
  const target = imageDir();
  try {
    const files = getFs().readdirSync(target);
    let size = 0;
    files.forEach((name) => {
      try {
        const stat = getFs().statSync(target + '/' + name);
        size += (stat.size || 0) / 1024;
      } catch (err) {
        // 单个文件读取失败忽略
      }
    });
    return { count: files.length, size: Math.round(size) };
  } catch (err) {
    return { count: 0, size: 0 };
  }
}

module.exports = {
  imageDir,
  userDataPath,
  ensureDir,
  extOf,
  isPng,
  isCancel,
  chooseImage,
  compress,
  getImageInfo,
  saveImage,
  saveBase64,
  toBase64,
  isOwned,
  removeFile,
  removeFiles,
  clearImages,
  getImagesStat,
};
