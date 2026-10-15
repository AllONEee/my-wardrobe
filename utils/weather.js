/**
 * utils/weather.js —— 天气接口封装（日记页「城市 / 温度 / 天气」卡片用）
 *
 * 小程序本身没有天气能力：wx 只提供 getLocation（经纬度），天气必须调第三方接口。
 * 常见三家，这里默认实现的是和风天气（免费订阅够个人用，且有历史天气）：
 *
 *  1. 和风天气 QWeather（默认）
 *     实况  https://devapi.qweather.com/v7/weather/now?location=<城市ID>&key=<KEY>
 *     预报  https://devapi.qweather.com/v7/weather/3d?location=<城市ID>&key=<KEY>   （免费版到 3 天）
 *     历史  https://devapi.qweather.com/v7/weather/historical?location=<城市ID>&date=YYYYMMDD&key=<KEY>
 *     查城市 https://geoapi.qweather.com/v2/city/lookup?location=<关键字>&key=<KEY>
 *  2. 心知天气 Seniverse：/v3/weather/now.json?key=&location=&language=zh-Hans&unit=c（没有历史天气）
 *  3. 高德开放平台「天气查询」：https://restapi.amap.com/v3/weather/weatherInfo?city=<adcode>&key=&extensions=base|all
 *     （只有实况与预报，没有历史天气）
 * 换一家只要改下面的 HOST 与 normalizeNow / normalizeDaily 两个适配函数。
 *
 * 三条工程约定（不满足就会「开发者工具里能跑、真机不行」）：
 *  1. 真机必须在小程序后台「开发管理 → 开发设置 → 服务器域名」里把用到的域名加进
 *     request 合法域名（和风天气是 devapi.qweather.com 与 geoapi.qweather.com）；
 *     本地调试可以在开发者工具里勾选「不校验合法域名」
 *  2. 历史天气不一定在免费额度里，拿不到就提示用户手填，绝不因此报错或卡住
 *  3. 取到的数据由日记页写进 storage（db.saveWeather），之后断网也能翻看
 */

const db = require('./db.js');
const dateUtil = require('./date.js');

const DEFAULT_HOST = 'https://devapi.qweather.com';
const DEFAULT_CITY_HOST = 'https://geoapi.qweather.com';
const TIMEOUT = 15000;
const FORECAST_DAYS = 3; // 免费版能查到的天数；订阅更高档位时同步调大

function getConfig() {
  return db.getWeatherConfig();
}

function setConfig(patch) {
  return db.saveWeatherConfig(patch);
}

function isConfigured() {
  const config = getConfig();
  return !!(config.enabled && config.apiKey);
}

function hostOf(config) {
  return (config.host || DEFAULT_HOST).replace(/\/+$/, '');
}

function cityHostOf(config) {
  return (config.cityHost || DEFAULT_CITY_HOST).replace(/\/+$/, '');
}

/* ==================== 请求 ==================== */

function request(url, data) {
  return new Promise((resolve, reject) => {
    wx.request({
      url,
      data,
      timeout: TIMEOUT,
      success: (res) => {
        if (res.statusCode !== 200) {
          reject(new Error('接口返回 ' + res.statusCode));
          return;
        }
        resolve(res.data || {});
      },
      fail: (err) => {
        // 真机上最常见的失败原因：域名没加进「request 合法域名」
        reject(new Error((err && err.errMsg) || '网络请求失败'));
      },
    });
  });
}

/** 和风天气用 code 表达业务错误，这里统一翻成人话 */
function assertOk(data) {
  const code = String((data && data.code) || '');
  if (code === '200') return data;
  const map = {
    204: '这个城市或日期没有数据',
    401: 'API Key 不对，或请求方式不对',
    402: 'Key 的额度用完了，或这个接口要付费订阅',
    403: '没有权限（历史天气可能不在免费额度里）',
    404: '不认识的请求地址',
    429: '请求太频繁，歇一下再试',
  };
  throw new Error(map[code] || '接口返回错误码 ' + (code || '未知'));
}

/* ==================== 城市 ==================== */

/**
 * 按关键字搜城市（和风天气 GeoAPI），返回 [{ id, name, adm }]
 */
function searchCity(keyword) {
  const word = String(keyword || '').trim();
  if (!word) return Promise.resolve([]);
  if (!isConfigured()) return Promise.reject(new Error('还没配置天气接口 Key'));

  const config = getConfig();
  return request(cityHostOf(config) + '/v2/city/lookup', {
    location: word,
    number: 10,
    lang: 'zh',
    key: config.apiKey,
  }).then((data) => {
    if (String(data.code) === '404') return [];
    assertOk(data);
    const list = Array.isArray(data.location) ? data.location : [];
    return list.map((item) => ({
      id: item.id,
      name: item.name,
      // adm1 是省 / 直辖市，adm2 是地级市；两者相同时只留一个，免得出现「北京 · 北京」
      adm: item.adm1 === item.adm2 ? item.adm1 : [item.adm1, item.adm2].filter(Boolean).join(' · '),
    }));
  });
}

/* ==================== 天气 ==================== */

/**
 * 按日期取某城市的天气：今天走实况，未来几天走预报，过去的日子走历史天气。
 * 返回 { temp, text, icon, kind }，temp 可能是「23」也可能是「18~25」。
 * @param {string} cityId 和风天气的城市 ID
 * @param {string} date 'YYYY-MM-DD'
 */
function fetchByDate(cityId, date) {
  const config = getConfig();
  if (!isConfigured()) return Promise.reject(new Error('还没配置天气接口 Key'));
  if (!cityId) return Promise.reject(new Error('先选一个城市'));

  const today = dateUtil.today();
  if (date === today) return fetchNow(config, cityId);
  if (date > today) return fetchForecast(config, cityId, date, today);
  return fetchHistorical(config, cityId, date);
}

function fetchNow(config, cityId) {
  return request(hostOf(config) + '/v7/weather/now', {
    location: cityId,
    lang: 'zh',
    key: config.apiKey,
  }).then((data) => {
    assertOk(data);
    const now = data.now || {};
    return { temp: String(now.temp || ''), text: now.text || '', icon: now.icon || '', kind: 'now' };
  });
}

function fetchForecast(config, cityId, date, today) {
  const gap = daysBetween(today, date);
  if (gap >= FORECAST_DAYS) {
    return Promise.reject(
      new Error('预报只能查到未来 ' + FORECAST_DAYS + ' 天，这天还太远，先手填吧')
    );
  }
  return request(hostOf(config) + '/v7/weather/' + FORECAST_DAYS + 'd', {
    location: cityId,
    lang: 'zh',
    key: config.apiKey,
  }).then((data) => {
    assertOk(data);
    const day = (data.daily || []).find((item) => item.fxDate === date);
    if (!day) throw new Error('预报里没有这一天');
    return normalizeDay(day, 'forecast');
  });
}

function fetchHistorical(config, cityId, date) {
  return request(hostOf(config) + '/v7/weather/historical', {
    location: cityId,
    date: date.replace(/-/g, ''),
    lang: 'zh',
    key: config.apiKey,
  }).then((data) => {
    assertOk(data);
    // 历史天气把当天数据放在 weatherDaily 里；有的档位返回的是 daily 数组
    const day = data.weatherDaily || (data.daily || [])[0];
    if (!day) throw new Error('这天没有历史天气数据');
    return normalizeDay(day, 'historical');
  });
}

function normalizeDay(day, kind) {
  return {
    temp: [day.tempMin, day.tempMax].filter((v) => v !== undefined && v !== '').join('~'),
    text: day.textDay || day.text || '',
    icon: day.iconDay || day.icon || '',
    kind,
  };
}

/** 两个 'YYYY-MM-DD' 相差多少天（按本地零点算，避免夏令时之类的小数） */
function daysBetween(from, to) {
  const a = dateUtil.parseDate(from).getTime();
  const b = dateUtil.parseDate(to).getTime();
  return Math.round((b - a) / 86400000);
}

module.exports = {
  DEFAULT_HOST,
  DEFAULT_CITY_HOST,
  getConfig,
  setConfig,
  isConfigured,
  searchCity,
  fetchByDate,
};
