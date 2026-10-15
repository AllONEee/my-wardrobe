/**
 * utils/date.js —— 日期工具
 *
 * 约定：业务里日期一律用 'YYYY-MM-DD' 字符串（本地时区），
 *      避免 iOS 上 new Date('2026-10-15') 被按 UTC 解析导致的差一天问题。
 */

function pad(n) {
  return n < 10 ? '0' + n : '' + n;
}

/** Date -> 'YYYY-MM-DD' */
function formatDate(date) {
  const d = date instanceof Date ? date : new Date(date);
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
}

/** 'YYYY-MM-DD' -> Date（本地时区，0 点） */
function parseDate(str) {
  if (str instanceof Date) return str;
  if (!str) return new Date();
  const parts = String(str).split('-');
  if (parts.length < 3) return new Date();
  return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
}

function today() {
  return formatDate(new Date());
}

function isSameDay(a, b) {
  return formatDate(parseDate(a)) === formatDate(parseDate(b));
}

function addDays(dateStr, days) {
  const d = parseDate(dateStr);
  d.setDate(d.getDate() + days);
  return formatDate(d);
}

/** 月份加减，返回 'YYYY-MM-DD'（该月 1 号） */
function addMonths(monthKey, delta) {
  const d = parseDate(monthKey);
  d.setDate(1);
  d.setMonth(d.getMonth() + delta);
  return formatDate(d);
}

/** 'YYYY-MM-DD' -> 'YYYY-MM' */
function monthKeyOf(dateStr) {
  return formatDate(parseDate(dateStr)).slice(0, 7);
}

function formatMonthTitle(monthKey) {
  const parts = String(monthKey).split('-');
  return Number(parts[0]) + '年' + Number(parts[1]) + '月';
}

function formatMonthDay(dateStr) {
  const d = parseDate(dateStr);
  return d.getMonth() + 1 + '月' + d.getDate() + '日';
}

/** 今天 / 昨天 / M月D日 */
function friendlyDate(dateStr) {
  const t = today();
  if (formatDate(parseDate(dateStr)) === t) return '今天';
  if (formatDate(parseDate(dateStr)) === addDays(t, -1)) return '昨天';
  const d = parseDate(dateStr);
  if (d.getFullYear() === new Date().getFullYear()) return formatMonthDay(dateStr);
  return d.getFullYear() + '年' + formatMonthDay(dateStr);
}

/**
 * 生成月历网格（周日开头），日记页直接用
 * @param {string} monthKey 'YYYY-MM'
 * @returns {Array<{date: string, day: number, month: number, inMonth: boolean, isToday: boolean, isFuture: boolean}>}
 */
function monthGrid(monthKey) {
  const parts = String(monthKey).split('-');
  const year = Number(parts[0]);
  const month = Number(parts[1]); // 1-12
  const firstDay = new Date(year, month - 1, 1);
  const startWeekday = firstDay.getDay(); // 0 = 周日
  const daysInMonth = new Date(year, month, 0).getDate();
  const t = today();
  const cells = [];

  // 前置补位（上个月的末尾几天）
  for (let i = 0; i < startWeekday; i++) {
    const d = new Date(year, month - 1, 1 - (startWeekday - i));
    cells.push(buildCell(d, month, t, false));
  }
  for (let day = 1; day <= daysInMonth; day++) {
    cells.push(buildCell(new Date(year, month - 1, day), month, t, true));
  }
  // 补到 6 行 * 7 列，保证高度稳定
  while (cells.length % 7 !== 0 || cells.length < 42) {
    const last = parseDate(cells[cells.length - 1].date);
    last.setDate(last.getDate() + 1);
    cells.push(buildCell(last, month, t, false));
    if (cells.length >= 42) break;
  }
  return cells;
}

function buildCell(d, month, todayStr, inMonth) {
  const dateStr = formatDate(d);
  return {
    date: dateStr,
    day: d.getDate(),
    month: d.getMonth() + 1,
    inMonth: d.getMonth() + 1 === Number(month) ? inMonth : false,
    isToday: dateStr === todayStr,
    isFuture: dateStr > todayStr,
  };
}

const WEEK_LABELS = ['日', '一', '二', '三', '四', '五', '六'];

module.exports = {
  pad,
  formatDate,
  parseDate,
  today,
  isSameDay,
  addDays,
  addMonths,
  monthKeyOf,
  formatMonthTitle,
  formatMonthDay,
  friendlyDate,
  monthGrid,
  WEEK_LABELS,
};
