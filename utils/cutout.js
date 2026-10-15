/**
 * utils/cutout.js —— 云端 AI 抠图接口封装（不依赖任何付费 SDK）
 *
 * 没配接口时：cutout() 直接返回原图（cloud: false），页面据此给用户提示，功能不阻塞。
 *
 * 接入步骤：
 *  1. 把下面的 CONFIG.apiUrl / apiKey 填成你自己的服务地址，或在小程序启动时调用
 *     cutout.setConfig({ apiUrl: 'https://xxx/api/cutout', apiKey: 'xxx', enabled: true })
 *  2. setConfig 会把配置写进 storage（wardrobe_cutout_config），所以换地址不用改代码重新提交审核
 *  3. 真机必须在小程序后台「开发管理 → 开发设置 → 服务器域名」里把接口域名加进
 *     request 合法域名 / uploadFile 合法域名；本地调试可在开发者工具里勾选「不校验合法域名」
 *
 * 服务端约定（如果你想用别的返回结构，改 adaptResult 就行）：
 *  请求：
 *    mode 'upload'（默认，走 wx.uploadFile，适合大图）
 *      POST apiUrl，multipart 表单，文件字段名 = CONFIG.fieldName
 *      formData 里会额外带 CONFIG.extraFormData
 *    mode 'json'
 *      POST apiUrl，JSON body：{ image: 'data:image/jpeg;base64,...' }
 *  响应（任选其一）：
 *    { "code": 0, "data": { "image": "<base64，可不带前缀>" } }
 *    { "code": 0, "data": { "url": "https://.../foreground.png" } }
 */

const storage = require('./storage.js');
const imageUtil = require('./image.js');

/** 默认配置：接口地址和 key 就写在这里，方便替换 */
const DEFAULT_CONFIG = {
  enabled: false, // 改成 true（并且填好 apiUrl）后即启用云端抠图
  apiUrl: '', // 例如 'https://your-server.com/api/cutout'
  apiKey: '',
  apiKeyHeader: 'X-API-Key',
  mode: 'upload', // 'upload' | 'json'
  fieldName: 'image', // mode=upload 时的文件字段名
  extraFormData: {}, // 附加参数，例如 { model: 'isnet' }
  timeout: 30000,
};

const STORAGE_KEY = storage.KEYS.CUTOUT_CONFIG;

let cachedConfig = null;

function getConfig() {
  if (cachedConfig) return cachedConfig;
  const saved = storage.get(STORAGE_KEY, null);
  cachedConfig = Object.assign({}, DEFAULT_CONFIG, saved && typeof saved === 'object' ? saved : {});
  return cachedConfig;
}

/**
 * 覆盖配置
 * @param {object} patch
 * @param {boolean} persist 默认 true，写进 storage，下次启动仍生效
 */
function setConfig(patch, persist) {
  cachedConfig = Object.assign({}, getConfig(), patch || {});
  if (persist !== false) storage.set(STORAGE_KEY, cachedConfig);
  return cachedConfig;
}

function isConfigured() {
  const config = getConfig();
  return !!(config.enabled && config.apiUrl);
}

/* ==================== 请求实现 ==================== */

function uploadRequest(config, imagePath) {
  return new Promise((resolve, reject) => {
    const formData = Object.assign({}, config.extraFormData);
    const header = {};
    if (config.apiKey) header[config.apiKeyHeader] = config.apiKey;

    const task = wx.uploadFile({
      url: config.apiUrl,
      filePath: imagePath,
      name: config.fieldName || 'image',
      formData,
      header,
      timeout: config.timeout,
      success(res) {
        resolve(parseResponse(res.data));
      },
      fail(err) {
        reject(new Error(readableError(err, '上传抠图失败')));
      },
    });
    // uploadFile 的 timeout 在部分基础库上不生效，这里兜底
    if (task && task.onProgressUpdate) {
      /* noop */
    }
  });
}

function jsonRequest(config, imagePath) {
  return imageUtil.toBase64(imagePath).then(
    (base64) =>
      new Promise((resolve, reject) => {
        const header = { 'content-type': 'application/json' };
        if (config.apiKey) header[config.apiKeyHeader] = config.apiKey;

        wx.request({
          url: config.apiUrl,
          method: 'POST',
          timeout: config.timeout,
          header,
          data: Object.assign({}, config.extraFormData, {
            image: 'data:image/jpeg;base64,' + base64,
          }),
          success(res) {
            if (res.statusCode >= 200 && res.statusCode < 300) {
              resolve(parseResponse(res.data));
              return;
            }
            reject(new Error('云端抠图接口返回 ' + res.statusCode));
          },
          fail(err) {
            reject(new Error(readableError(err, '请求抠图接口失败')));
          },
        });
      })
  );
}

function parseResponse(data) {
  if (data && typeof data === 'string') {
    try {
      return JSON.parse(data);
    } catch (err) {
      return { raw: data };
    }
  }
  return data;
}

/**
 * 兼容几种常见的返回结构，拿到前景图（base64 或 url）
 * 服务端结构不同的话只改这个函数
 */
function adaptResult(payload) {
  if (!payload) return null;
  const body = payload.data && typeof payload.data === 'object' ? payload.data : payload;

  if (typeof payload === 'string') return { base64: payload };
  if (typeof body.image === 'string') return { base64: body.image };
  if (typeof body.base64 === 'string') return { base64: body.base64 };
  if (typeof body.result === 'string' && body.result.indexOf('http') !== 0) {
    return { base64: body.result };
  }
  if (typeof body.url === 'string') return { url: body.url };
  if (typeof body.imageUrl === 'string') return { url: body.imageUrl };
  return null;
}

function downloadToLocal(url) {
  return new Promise((resolve, reject) => {
    wx.downloadFile({
      url,
      success(res) {
        if (res.statusCode === 200 && res.tempFilePath) {
          imageUtil
            .saveImage(res.tempFilePath, { prefix: 'cut', compress: 'auto' })
            .then((saved) => resolve(saved.path))
            .catch(reject);
          return;
        }
        reject(new Error('下载抠图结果失败：' + res.statusCode));
      },
      fail(err) {
        reject(new Error(readableError(err, '下载抠图结果失败')));
      },
    });
  });
}

function readableError(err, fallback) {
  const msg = (err && (err.errMsg || err.message)) || '';
  if (msg.indexOf('domain') >= 0 || msg.indexOf('合法域名') >= 0) {
    return '接口域名未配置合法域名，请在小程序后台添加';
  }
  if (msg.indexOf('timeout') >= 0) return '抠图接口超时，请稍后重试';
  return msg || fallback;
}

/* ==================== 对外方法 ==================== */

/**
 * 抠图
 * @param {string} imagePath 图片路径（原图或临时文件）
 * @param {object} options 可临时覆盖 getConfig() 里的字段
 * @returns {Promise<{path: string, cloud: boolean, reason: string, message: string}>}
 *          cloud=false 表示走了本地兜底（未配置接口），path 就是原图
 *          cloud=true 时 path 是抠好的前景图本地路径（PNG，带透明通道）
 */
function cutout(imagePath, options) {
  const config = Object.assign({}, getConfig(), options || {});

  if (!(config.enabled && config.apiUrl)) {
    return Promise.resolve({
      path: imagePath,
      cloud: false,
      reason: 'unconfigured',
      message: '未配置云端抠图接口，已返回原图（可继续用画笔/橡皮擦手动处理）',
    });
  }
  if (!imagePath) {
    return Promise.reject(new Error('缺少图片路径'));
  }

  const request = config.mode === 'json' ? jsonRequest : uploadRequest;

  return request(config, imagePath)
    .then((payload) => {
      // 服务端明确返回了错误码
      if (payload && typeof payload.code !== 'undefined' && Number(payload.code) !== 0) {
        throw new Error(payload.message || payload.msg || '抠图接口返回失败');
      }
      const adapted = adaptResult(payload);
      if (!adapted) throw new Error('抠图接口返回结构无法识别，请检查 adaptResult');
      if (adapted.base64) {
        return imageUtil.saveBase64(adapted.base64, { prefix: 'cut', ext: '.png' });
      }
      return downloadToLocal(adapted.url);
    })
    .then((path) => ({ path, cloud: true, reason: '', message: '' }));
}

module.exports = {
  DEFAULT_CONFIG,
  getConfig,
  setConfig,
  isConfigured,
  cutout,
};
