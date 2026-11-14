// Pure data model and layout math for the Photos timeline:
// day grouping across DST, grid row layout, binary search rowAt, and year marks.

function formatDayKey(dtf, ms) {
  const str = dtf.format(ms);
  if (/^\d{4}-\d{2}-\d{2}$/.test(str)) return str;
  const parts = dtf.formatToParts(ms);
  let y = "", m = "", d = "";
  for (const p of parts) {
    if (p.type === "year") y = p.value;
    else if (p.type === "month") m = p.value;
    else if (p.type === "day") d = p.value;
  }
  return `${y}-${m}-${d}`;
}

/**
 * Groups timestamps (unix seconds, newest first) into day sections.
 * Correct across daylight saving time transitions (clocks jumping forward or back).
 * @param {number[]} mtimes
 * @param {string} [timeZone] Optional IANA timezone, e.g. "America/Santiago", "Europe/Madrid"
 * @returns {{ key: string, label: string, start: number, count: number }[]}
 */
export function groupByDay(mtimes, timeZone) {
  if (!mtimes || mtimes.length === 0) return [];

  const keyOpts = { year: "numeric", month: "2-digit", day: "2-digit" };
  if (timeZone) keyOpts.timeZone = timeZone;
  const keyDtf = new Intl.DateTimeFormat("en-CA", keyOpts);

  const labelOpts = { year: "numeric", month: "short", day: "numeric" };
  if (timeZone) labelOpts.timeZone = timeZone;
  const labelDtf = new Intl.DateTimeFormat(undefined, labelOpts);

  const sections = [];
  let currentSec = null;

  for (let i = 0; i < mtimes.length; i++) {
    const ms = mtimes[i] * 1000;
    const key = formatDayKey(keyDtf, ms);

    if (!currentSec || currentSec.key !== key) {
      currentSec = {
        key,
        label: labelDtf.format(ms),
        start: i,
        count: 1,
      };
      sections.push(currentSec);
    } else {
      currentSec.count++;
    }
  }

  return sections;
}

/**
 * Computes virtual row heights and positions for day headers and tile rows.
 * @param {Array<{ key: string, label: string, start: number, count: number }>} sections
 * @param {number} width Available container width in px
 * @param {number} [tileTarget=120] Target tile width/height
 * @param {number} [gap=4] Gap between tiles and tile rows
 * @param {number} [headerH=40] Height of section day headers
 * @returns {Array<{ type: "header"|"tiles", top: number, h: number, start: number, n: number }> & { rows: any[], totalHeight: number, cols: number, tileSize: number }}
 */
export function layout(sections, width, tileTarget = 120, gap = 4, headerH = 40) {
  const cols = width > 0 ? Math.max(1, Math.round((width + gap) / (tileTarget + gap))) : 1;
  const tileSize = width > 0 ? Math.max(1, Math.floor((width - (cols - 1) * gap) / cols)) : tileTarget;

  const rows = [];
  let top = 0;

  for (let sIdx = 0; sIdx < sections.length; sIdx++) {
    const sec = sections[sIdx];
    // Section header
    rows.push({
      type: "header",
      top,
      h: headerH,
      start: sec.start,
      n: 0,
      key: sec.key,
      label: sec.label,
      sectionIndex: sIdx,
    });
    top += headerH;

    // Tile rows
    let offset = 0;
    let left = sec.count;
    while (left > 0) {
      const n = Math.min(cols, left);
      rows.push({
        type: "tiles",
        top,
        h: tileSize,
        start: sec.start + offset,
        n,
        cols,
        gap,
        tileSize,
        sectionIndex: sIdx,
      });
      top += tileSize + gap;
      offset += n;
      left -= n;
    }
  }

  const totalHeight = rows.length > 0 ? rows[rows.length - 1].top + rows[rows.length - 1].h : 0;
  rows.rows = rows;
  rows.totalHeight = totalHeight;
  rows.cols = cols;
  rows.tileSize = tileSize;
  return rows;
}

/**
 * Finds the row index active at the given scrollTop using binary search.
 * @param {Array<{ top: number, h: number }>} rows
 * @param {number} scrollTop
 * @returns {number} Row index, or -1 if rows is empty
 */
export function rowAt(rows, scrollTop) {
  if (!rows || rows.length === 0) return -1;
  if (scrollTop <= rows[0].top) return 0;
  const last = rows.length - 1;
  if (scrollTop >= rows[last].top) return last;

  let low = 0;
  let high = last;
  let ans = 0;

  while (low <= high) {
    const mid = (low + high) >> 1;
    if (rows[mid].top <= scrollTop) {
      ans = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return ans;
}

/**
 * Returns distinct year markers for a year scrubber.
 * @param {Array<{ key: string, start: number }>} sections
 * @param {Array<{ type: string, start: number, top: number }>} rows
 * @returns {Array<{ year: number, label: string, top: number, rowIndex: number, sectionIndex: number, ratio: number }>}
 */
export function yearMarks(sections, rows) {
  if (!sections || !rows || sections.length === 0 || rows.length === 0) return [];
  const totalHeight = rows.totalHeight || (rows.length > 0 ? rows[rows.length - 1].top + rows[rows.length - 1].h : 0);
  const marks = [];
  const seenYears = new Set();

  const headerRowMap = new Map();
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (r.type === "header") {
      headerRowMap.set(r.start, { row: r, index: i });
    }
  }

  for (let sIdx = 0; sIdx < sections.length; sIdx++) {
    const sec = sections[sIdx];
    const yearStr = sec.key.slice(0, 4);
    const year = parseInt(yearStr, 10);
    if (!seenYears.has(year)) {
      seenYears.add(year);
      const headerInfo = headerRowMap.get(sec.start);
      const top = headerInfo ? headerInfo.row.top : 0;
      const rowIndex = headerInfo ? headerInfo.index : 0;
      marks.push({
        year,
        label: yearStr,
        top,
        rowIndex,
        sectionIndex: sIdx,
        ratio: totalHeight > 0 ? top / totalHeight : 0,
      });
    }
  }

  return marks;
}
