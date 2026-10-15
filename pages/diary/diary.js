/**
 * pages/diary —— 穿搭日记
 *
 * 结构：上面是月历（有记录的日期打点），下面是选中那天的穿搭列表。
 * 一天可以有多套穿搭，每套都能单独设封面（用关联衣物的图，或从相册选一张）。
 *
 * 天气卡片：记下那天的城市 / 温度 / 天气。
 *  - 手填永远可用（不依赖任何接口，也能离线用）
 *  - 配了天气接口 Key（见 utils/weather.js）后，「获取天气」会按城市自动抓：
 *    今天取实况、未来几天取预报、过去的日子取历史天气，抓到的结果按日期存进 storage
 *
 * 说明：
 *  - 月历网格由 utils/date.js 的 monthGrid 生成（固定 6 行 7 列，切换月份时高度不跳）
 *  - 切月份时选中日期跟着落到「该月 1 号 / 今天」，避免日历和下面的列表对不上
 *  - 自定义封面图是我们自己沙箱里的文件，换封面 / 删穿搭时只在「没有别处引用」时才删掉
 */
const db = require('../../utils/db.js');
const store = require('../../store/global.js');
const dateUtil = require('../../utils/date.js');
const imageUtil = require('../../utils/image.js');
const weatherApi = require('../../utils/weather.js');

const MAX_THUMBS = 6;
/** 手动选天气时的常用选项（接口返回的其它说法会自动补进胶囊里） */
const WEATHER_OPTIONS = ['晴', '多云', '阴', '小雨', '中雨', '大雨', '雷阵雨', '雪', '雾', '霾'];

Page({
  data: {
    weekLabels: dateUtil.WEEK_LABELS,
    monthKey: '',
    monthTitle: '',
    cells: [],
    selectedDate: '',
    selectedLabel: '',
    outfits: [],
    totalOutfits: 0,
    totalDays: 0,

    weather: { city: '', temp: '', text: '' },
    weatherChips: [],
    weatherSourceText: '',
    weatherConfigured: false,
  },

  onLoad() {
    const today = dateUtil.today();
    this._today = today;
    this.setData({
      selectedDate: today,
      monthKey: dateUtil.monthKeyOf(today),
    });

    // 任何地方的穿搭 / 衣物变化都会派发事件，这里跟着刷新
    store.on(store.EVENTS.OUTFIT_CHANGE, this.refresh, this);
    store.on(store.EVENTS.CLOTHING_CHANGE, this.refresh, this);
  },

  onShow() {
    // 从编辑页 / 详情页返回时兜底刷新一次
    this.refresh();
  },

  onUnload() {
    store.offByCtx(this);
  },

  /* ==================== 数据 ==================== */

  refresh() {
    const counts = db.countOutfitsByDate();
    const dates = db.listOutfitDates();
    const selectedDate = this.data.selectedDate || this._today;

    const cells = dateUtil.monthGrid(this.data.monthKey).map((cell) =>
      Object.assign({}, cell, {
        count: counts[cell.date] || 0,
        selected: cell.date === selectedDate,
      })
    );

    this.setData({
      cells,
      monthTitle: dateUtil.formatMonthTitle(this.data.monthKey),
      selectedLabel: this.labelOf(selectedDate),
      outfits: this.buildOutfits(selectedDate),
      totalOutfits: db.listOutfits().length,
      totalDays: dates.length,
    });
    this.loadWeather(selectedDate);
  },

  /** 当天穿搭 + 展示用字段（封面、衣物缩略图） */
  buildOutfits(date) {
    const outfits = db.listOutfits({ date });
    if (!outfits.length) return [];

    // 衣物一次性读出来做成 map，别在循环里反复读 storage
    const map = {};
    db.listClothing().forEach((item) => {
      map[item.id] = item;
    });

    return outfits.map((outfit) => {
      const items = (outfit.clothingIds || []).map((id) => map[id]).filter(Boolean);
      const thumbs = items.slice(0, MAX_THUMBS).map((item) => ({
        id: item.id,
        image: item.coverImage || item.originalImage || '',
      }));
      const firstImage = thumbs.length ? thumbs[0].image : '';
      const seasons = outfit.seasons || [];
      return {
        id: outfit.id,
        cover: outfit.cover || firstImage,
        hasCover: !!outfit.cover,
        note: outfit.note || '',
        thumbs,
        more: Math.max(0, items.length - thumbs.length),
        // 顺带把「我的搭配」里标的季节显示出来，回看时一眼知道这套属于哪一季
        countText: items.length + ' 件衣物' + (seasons.length ? ' · ' + seasons.join('/') : ''),
      };
    });
  },

  labelOf(date) {
    const weekday = '周' + dateUtil.WEEK_LABELS[dateUtil.parseDate(date).getDay()];
    return dateUtil.friendlyDate(date) + ' · ' + weekday;
  },

  /* ==================== 天气 ==================== */

  /** 把这一天的天气记录搬进 data（选中的日期变了要重新读） */
  loadWeather(date) {
    const record = this.withLastCity(db.getWeather(date) || {});
    this._weather = record;
    this.setData({
      weather: {
        city: record.city || '',
        temp: record.temp || '',
        text: record.text || '',
      },
      weatherChips: this.buildWeatherChips(record.text),
      weatherSourceText: this.weatherSourceText(record),
      weatherConfigured: weatherApi.isConfigured(),
    });
  },

  /**
   * 没记过城市的一天：拿上次用过的城市打个底，切到新日期点「获取天气」就能直接用。
   * 只用于显示与取数，不落库 —— 真正记下来的是用户选过 / 抓过天气的那一次。
   */
  withLastCity(record) {
    if (record.city) return record;
    const last = weatherApi.getConfig().lastCity;
    if (!last || !last.name) return record;
    return Object.assign({}, record, { city: last.name, cityId: last.id || '' });
  },

  buildWeatherChips(text) {
    // 接口给的说法如果不在常用列表里（比如「浮尘」），补一个胶囊，免得不显示
    const options = WEATHER_OPTIONS.slice();
    if (text && options.indexOf(text) < 0) options.push(text);
    return options.map((value) => ({ value, active: value === text }));
  },

  weatherSourceText(record) {
    if (!record || (!record.temp && !record.text)) return '';
    if (record.source === 'api') {
      return '自动获取 · ' + this.timeText(record.updateTime);
    }
    return '手动填写';
  },

  timeText(ts) {
    if (!ts) return '';
    const d = new Date(ts);
    return dateUtil.formatMonthDay(dateUtil.formatDate(d)) + ' ' + dateUtil.pad(d.getHours()) + ':' + dateUtil.pad(d.getMinutes());
  },

  onWeatherInput(e) {
    const value = e.detail.value;
    this.setData({ 'weather.temp': value });
    this.saveWeather({ temp: String(value || '').trim() });
  },

  onWeatherTap(e) {
    const value = e.currentTarget.dataset.value;
    const text = value === this.data.weather.text ? '' : value;
    this.setData({ 'weather.text': text, weatherChips: this.buildWeatherChips(text) });
    this.saveWeather({ text });
  },

  /** 任何一次手填都算「手动填写」，并且顺手清掉上一次自动获取的信息 */
  saveWeather(patch) {
    const saved = db.saveWeather(
      this.data.selectedDate,
      Object.assign({ source: 'manual', icon: '' }, patch)
    );
    // 记录被清空（城市、温度、天气都没了）时留着内存里那份，接着取天气还能用上城市
    this._weather = saved || this._weather || {};
    this.setData({ weatherSourceText: this.weatherSourceText(this._weather) });
  },

  onPickCity() {
    // 配了接口就搜城市（拿到城市 ID 才能自动取天气），没配就手填一个名字
    if (weatherApi.isConfigured()) this.searchCity();
    else this.inputCityName();
  },

  inputCityName() {
    wx.showModal({
      title: '城市',
      editable: true,
      content: this.data.weather.city || '',
      placeholderText: '例如：杭州',
      success: (res) => {
        if (!res.confirm) return;
        const name = String(res.content || '').trim();
        this.setData({ 'weather.city': name });
        this.saveWeather({ city: name, cityId: '' });
      },
    });
  },

  searchCity() {
    wx.showModal({
      title: '搜索城市',
      editable: true,
      placeholderText: '例如：杭州 / 三亚 / 京都',
      success: (res) => {
        if (!res.confirm) return;
        const keyword = String(res.content || '').trim();
        if (!keyword) return;

        wx.showLoading({ title: '搜索中…', mask: true });
        weatherApi
          .searchCity(keyword)
          .then((list) => {
            wx.hideLoading();
            if (!list.length) {
              wx.showToast({ title: '没找到这个城市', icon: 'none' });
              return;
            }
            const visible = list.slice(0, 6); // showActionSheet 最多 6 项
            wx.showActionSheet({
              itemList: visible.map((item) => (item.adm ? item.name + ' · ' + item.adm : item.name)),
              success: (r) => {
                const city = visible[r.tapIndex];
                if (!city) return;
                this.setData({ 'weather.city': city.name });
                db.saveWeather(this.data.selectedDate, { city: city.name, cityId: city.id });
                db.saveWeatherConfig({ lastCity: { id: city.id, name: city.name } });
                this.loadWeather(this.data.selectedDate);
                this.fetchWeather(); // 选完城市顺手把那天的天气抓回来
              },
              fail: () => {},
            });
          })
          .catch((err) => {
            wx.hideLoading();
            this.showWeatherError(err);
          });
      },
      fail: () => {},
    });
  },

  /* ==================== 天气：自动获取 ==================== */

  onFetchWeather() {
    if (this._fetching) return;
    if (!weatherApi.isConfigured()) {
      this.askApiKey();
      return;
    }
    const cityId = (this._weather && this._weather.cityId) || '';
    if (!cityId) {
      wx.showToast({ title: '先选一个城市', icon: 'none' });
      this.searchCity();
      return;
    }
    this.fetchWeather();
  },

  fetchWeather() {
    const date = this.data.selectedDate;
    const record = this._weather || db.getWeather(date) || {};
    if (!record.cityId) return;

    this._fetching = true;
    wx.showLoading({ title: '获取天气…', mask: true });
    weatherApi
      .fetchByDate(record.cityId, date)
      .then((res) => {
        wx.hideLoading();
        this._fetching = false;
        db.saveWeather(date, {
          city: record.city,
          cityId: record.cityId,
          temp: res.temp,
          text: res.text,
          icon: res.icon,
          source: 'api',
        });
        this.loadWeather(date);
        wx.showToast({
          title: '已获取 ' + [res.text, res.temp ? res.temp + '℃' : ''].filter(Boolean).join(' '),
          icon: 'none',
        });
      })
      .catch((err) => {
        wx.hideLoading();
        this._fetching = false;
        this.showWeatherError(err);
      });
  },

  /** 没配接口时，引导填一个 Key（也可以继续手填） */
  askApiKey() {
    wx.showModal({
      title: '自动获取天气',
      content:
        '小程序自身没有天气数据，需要接一个第三方接口。填一个和风天气（QWeather）的免费 API Key 就能按城市自动获取；不想配也可以直接手填城市、温度和天气。',
      confirmText: '填 Key',
      cancelText: '先手填',
      success: (res) => {
        if (!res.confirm) return;
        wx.showModal({
          title: '和风天气 API Key',
          editable: true,
          placeholderText: '在 dev.qweather.com 免费申请',
          success: (r2) => {
            if (!r2.confirm) return;
            const apiKey = String(r2.content || '').trim();
            if (!apiKey) return;
            db.saveWeatherConfig({ apiKey, enabled: true });
            this.setData({ weatherConfigured: true });
            wx.showToast({ title: '已保存，先选个城市', icon: 'none' });
            this.searchCity();
          },
        });
      },
      fail: () => {},
    });
  },

  showWeatherError(err) {
    const message = (err && err.message) || '获取失败';
    wx.showModal({
      title: '没能拿到天气',
      content:
        message +
        '\n\n常见原因：接口域名没加进小程序后台的「request 合法域名」、Key 不对或额度用完、该日期的历史天气不在免费额度内。拿不到也不影响记录，直接在卡片里手填即可。',
      showCancel: false,
      confirmText: '知道了',
    });
  },

  /* ==================== 日历 ==================== */

  onDayTap(e) {
    const date = e.currentTarget.dataset.date;
    if (!date) return;
    const monthKey = dateUtil.monthKeyOf(date);
    this.setData({
      selectedDate: date,
      // 点到上/下个月的补位格子时，顺手把月历也切过去
      monthKey: monthKey === this.data.monthKey ? this.data.monthKey : monthKey,
    });
    this.refresh();
  },

  onPrevMonth() {
    this.switchMonth(-1);
  },

  onNextMonth() {
    this.switchMonth(1);
  },

  switchMonth(delta) {
    // addMonths 收的是 'YYYY-MM-DD'（内部按本地时区解析），所以补上 1 号再算
    const monthKey = dateUtil.monthKeyOf(dateUtil.addMonths(this.data.monthKey + '-01', delta));
    const todayKey = dateUtil.monthKeyOf(this._today);
    this.setData({
      monthKey,
      selectedDate: monthKey === todayKey ? this._today : monthKey + '-01',
    });
    this.refresh();
  },

  onToday() {
    this.setData({
      monthKey: dateUtil.monthKeyOf(this._today),
      selectedDate: this._today,
    });
    this.refresh();
  },

  /* ==================== 跳转 ==================== */

  onAdd() {
    wx.navigateTo({
      url: '/pages/outfit-edit/outfit-edit?date=' + this.data.selectedDate,
    });
  },

  onOpenOutfit(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    wx.navigateTo({ url: '/pages/outfit-detail/outfit-detail?id=' + id });
  },

  /* ==================== 设置封面 ==================== */

  onSetCover(e) {
    const id = e.currentTarget.dataset.id;
    const outfit = db.getOutfit(id);
    if (!outfit) return;

    const items = db.listClothingByIds(outfit.clothingIds).filter(
      (item) => item.coverImage || item.originalImage
    );
    const actions = [];
    if (items.length) actions.push('用关联衣物的图片');
    actions.push('从相册选一张');
    if (outfit.cover) actions.push('恢复默认封面');

    wx.showActionSheet({
      itemList: actions,
      success: (res) => {
        const label = actions[res.tapIndex];
        if (label === '用关联衣物的图片') this.pickCoverFromClothing(id, items);
        else if (label === '从相册选一张') this.pickCoverFromAlbum(id);
        else this.applyCover(id, '');
      },
      fail: () => {},
    });
  },

  pickCoverFromClothing(id, items) {
    wx.showActionSheet({
      itemList: items.map((item) => item.name).slice(0, 6),
      success: (res) => {
        const item = items[res.tapIndex];
        if (item) this.applyCover(id, item.coverImage || item.originalImage);
      },
      fail: () => {},
    });
  },

  pickCoverFromAlbum(id) {
    imageUtil
      .chooseImage({ count: 1 })
      .then((paths) => imageUtil.saveImage(paths[0], { prefix: 'outfit-cover' }))
      .then((saved) => this.applyCover(id, saved.path))
      .catch((err) => {
        if (imageUtil.isCancel(err)) return;
        console.error('[diary] 选图失败', err);
        wx.showToast({ title: '选图失败，请重试', icon: 'none' });
      });
  },

  applyCover(id, cover) {
    const outfit = db.getOutfit(id);
    if (!outfit) return;
    db.updateOutfit(id, { cover });

    // 换掉的旧封面如果只属于这套穿搭，顺手删掉，别让图片目录越攒越大
    const old = outfit.cover;
    if (old && old !== cover && !db.isImageInUse(old)) imageUtil.removeFile(old);

    wx.showToast({ title: cover ? '封面已更新' : '已恢复默认封面', icon: 'none' });
  },
});
