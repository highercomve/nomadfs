import test from "node:test";
import assert from "node:assert/strict";
import {
  groupByDay,
  layout,
  rowAt,
  yearMarks,
} from "../frontend/photos-model.js";

test("groupByDay: empty or invalid inputs", () => {
  assert.deepEqual(groupByDay([]), []);
  assert.deepEqual(groupByDay(null), []);
  assert.deepEqual(groupByDay(undefined), []);
});

test("groupByDay: grouping across daylight saving transitions in Europe/Madrid", () => {
  const tz = "Europe/Madrid";

  // Spring forward: March 31, 2024.
  // 2024-03-30 23:00 UTC = 2024-03-31 00:00 CET (start of day)
  // 2024-03-31 00:30 UTC = 2024-03-31 01:30 CET
  // 2024-03-31 01:30 UTC = 2024-03-31 03:30 CEST (after spring forward jump)
  // 2024-03-31 21:30 UTC = 2024-03-31 23:30 CEST (end of day)
  // 2024-03-31 22:30 UTC = 2024-04-01 00:30 CEST (next day)
  const d_next = Math.floor(new Date("2024-04-01T00:30:00+02:00").getTime() / 1000);
  const d_end = Math.floor(new Date("2024-03-31T23:30:00+02:00").getTime() / 1000);
  const d_after_jump = Math.floor(new Date("2024-03-31T03:30:00+02:00").getTime() / 1000);
  const d_before_jump = Math.floor(new Date("2024-03-31T01:30:00+01:00").getTime() / 1000);
  const d_prev = Math.floor(new Date("2024-03-30T22:30:00+01:00").getTime() / 1000);

  // Newest first
  const mtimes = [d_next, d_end, d_after_jump, d_before_jump, d_prev];
  const sections = groupByDay(mtimes, tz);

  assert.equal(sections.length, 3);
  assert.equal(sections[0].key, "2024-04-01");
  assert.equal(sections[0].start, 0);
  assert.equal(sections[0].count, 1);

  assert.equal(sections[1].key, "2024-03-31");
  assert.equal(sections[1].start, 1);
  assert.equal(sections[1].count, 3); // d_end, d_after_jump, d_before_jump are all 2024-03-31

  assert.equal(sections[2].key, "2024-03-30");
  assert.equal(sections[2].start, 4);
  assert.equal(sections[2].count, 1);
});

test("groupByDay: autumn fall-back transition in America/Santiago", () => {
  const tz = "America/Santiago";

  // Santiago 2024: April 6, clocks fell back 1 hour at 23:59:59 (-03:00) to 23:00:00 (-04:00).
  const t_next = Math.floor(new Date("2024-04-07T08:00:00-04:00").getTime() / 1000);
  const t_late2 = Math.floor(new Date("2024-04-06T23:45:00-04:00").getTime() / 1000);
  const t_late1 = Math.floor(new Date("2024-04-06T23:15:00-03:00").getTime() / 1000);
  const t_noon = Math.floor(new Date("2024-04-06T12:00:00-03:00").getTime() / 1000);
  const t_prev = Math.floor(new Date("2024-04-05T18:00:00-03:00").getTime() / 1000);

  const sections = groupByDay([t_next, t_late2, t_late1, t_noon, t_prev], tz);

  assert.equal(sections.length, 3);
  assert.equal(sections[0].key, "2024-04-07");
  assert.equal(sections[0].count, 1);
  assert.equal(sections[1].key, "2024-04-06");
  assert.equal(sections[1].count, 3);
  assert.equal(sections[2].key, "2024-04-05");
  assert.equal(sections[2].count, 1);
});

test("groupByDay: default local timezone", () => {
  const now = Math.floor(Date.now() / 1000);
  const yesterday = now - 86400;
  const sections = groupByDay([now, now - 10, yesterday]);
  assert.ok(sections.length >= 1);
  assert.equal(sections[0].start, 0);
  assert.ok(sections[0].label.length > 0);
});

test("layout: row calculation, columns, heights, and positions", () => {
  const sections = [
    { key: "2026-11-11", label: "Nov 11, 2026", start: 0, count: 5 },
    { key: "2026-11-10", label: "Nov 10, 2026", start: 5, count: 2 },
  ];

  // width = 368, tileTarget = 120, gap = 4 -> (368 + 4) / (120 + 4) = 372 / 124 = 3 columns.
  // tileSize = (368 - 2 * 4) / 3 = 360 / 3 = 120.
  const rows = layout(sections, 368, 120, 4, 40);

  assert.equal(rows.cols, 3);
  assert.equal(rows.tileSize, 120);

  // Section 0 (5 items, cols=3):
  // Row 0: header (top: 0, h: 40)
  // Row 1: tiles (top: 40, h: 120, start: 0, n: 3)
  // Row 2: tiles (top: 164, h: 120, start: 3, n: 2) -> (40 + 120 + 4 = 164)
  // Section 1 (2 items, cols=3):
  // Row 3: header (top: 288, h: 40, start: 5, n: 0) -> (164 + 120 + 4 = 288)
  // Row 4: tiles (top: 328, h: 120, start: 5, n: 2) -> (288 + 40 = 328)
  assert.equal(rows.length, 5);

  assert.equal(rows[0].type, "header");
  assert.equal(rows[0].top, 0);
  assert.equal(rows[0].h, 40);
  assert.equal(rows[0].start, 0);

  assert.equal(rows[1].type, "tiles");
  assert.equal(rows[1].top, 40);
  assert.equal(rows[1].h, 120);
  assert.equal(rows[1].start, 0);
  assert.equal(rows[1].n, 3);

  assert.equal(rows[2].type, "tiles");
  assert.equal(rows[2].top, 164);
  assert.equal(rows[2].h, 120);
  assert.equal(rows[2].start, 3);
  assert.equal(rows[2].n, 2);

  assert.equal(rows[3].type, "header");
  assert.equal(rows[3].top, 288);
  assert.equal(rows[3].h, 40);
  assert.equal(rows[3].start, 5);

  assert.equal(rows[4].type, "tiles");
  assert.equal(rows[4].top, 328);
  assert.equal(rows[4].h, 120);
  assert.equal(rows[4].start, 5);
  assert.equal(rows[4].n, 2);

  // totalHeight: last row top (328) + h (120) = 448
  assert.equal(rows.totalHeight, 448);
  // Destructuring { rows, totalHeight } works too
  const { totalHeight, rows: innerRows } = rows;
  assert.equal(totalHeight, 448);
  assert.equal(innerRows.length, 5);
});

test("rowAt: binary search boundaries", () => {
  const rows = [
    { top: 0, h: 40 },
    { top: 40, h: 120 },
    { top: 164, h: 120 },
    { top: 288, h: 40 },
    { top: 328, h: 120 },
  ];

  // Empty check
  assert.equal(rowAt([], 100), -1);

  // Below top
  assert.equal(rowAt(rows, -50), 0);
  assert.equal(rowAt(rows, 0), 0);
  assert.equal(rowAt(rows, 20), 0);
  assert.equal(rowAt(rows, 39.9), 0);

  // Exact boundary of row 1
  assert.equal(rowAt(rows, 40), 1);
  assert.equal(rowAt(rows, 100), 1);
  assert.equal(rowAt(rows, 163.9), 1);

  // Exact boundary of row 2
  assert.equal(rowAt(rows, 164), 2);
  assert.equal(rowAt(rows, 200), 2);

  // Exact boundary of row 3
  assert.equal(rowAt(rows, 288), 3);
  assert.equal(rowAt(rows, 300), 3);

  // Exact boundary of row 4 (last row)
  assert.equal(rowAt(rows, 328), 4);
  assert.equal(rowAt(rows, 400), 4);
  assert.equal(rowAt(rows, 5000), 4);
});

test("yearMarks: extracting scrubber year marks", () => {
  const sections = [
    { key: "2026-11-11", label: "Nov 11, 2026", start: 0, count: 3 },
    { key: "2026-05-01", label: "May 1, 2026", start: 3, count: 2 },
    { key: "2025-12-25", label: "Dec 25, 2025", start: 5, count: 4 },
    { key: "2024-01-01", label: "Jan 1, 2024", start: 9, count: 1 },
  ];

  const rows = layout(sections, 368, 120, 4, 40);
  const marks = yearMarks(sections, rows);

  assert.equal(marks.length, 3);
  assert.equal(marks[0].year, 2026);
  assert.equal(marks[0].label, "2026");
  assert.equal(marks[0].top, 0);
  assert.equal(marks[0].sectionIndex, 0);

  assert.equal(marks[1].year, 2025);
  assert.equal(marks[1].label, "2025");
  assert.ok(marks[1].top > 0);
  assert.equal(marks[1].sectionIndex, 2);

  assert.equal(marks[2].year, 2024);
  assert.equal(marks[2].label, "2024");
  assert.ok(marks[2].top > marks[1].top);
  assert.equal(marks[2].sectionIndex, 3);
});
