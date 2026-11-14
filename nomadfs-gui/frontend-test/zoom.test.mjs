import { test } from "node:test";
import assert from "node:assert/strict";
import { initial, zoomAt, pan, clamp, isZoomed, MAX_SCALE } from "../frontend/zoom.js";

test("zoomAt keeps the point under the cursor still", () => {
  // Photo 400×300; zoom 2× at a point 100px right, 50px down of its centre.
  const v = zoomAt(initial(), 2, 100, 50, 400, 300);
  assert.equal(v.scale, 2);
  // That point (u = 100,50 unscaled) now shows at t + 2u: still at 100,50.
  assert.equal(v.tx + 2 * 100, 100);
  assert.equal(v.ty + 2 * 50, 50);
});

test("zoom is clamped to 1..MAX and back to centred at 1×", () => {
  let v = zoomAt(initial(), 100, 0, 0, 400, 300);
  assert.equal(v.scale, MAX_SCALE);
  v = zoomAt(v, 0.0001, 50, 50, 400, 300);
  assert.deepEqual(v, { scale: 1, tx: 0, ty: 0 });
  assert.equal(isZoomed(v), false);
});

test("pan stops at the photo's edges", () => {
  const v = pan({ scale: 2, tx: 0, ty: 0 }, 10_000, -10_000, 400, 300);
  // At 2× a 400×300 photo may move 200 px sideways and 150 px up/down.
  assert.deepEqual(v, { scale: 2, tx: 200, ty: -150 });
  assert.deepEqual(clamp({ scale: 1, tx: 30, ty: -5 }, 400, 300), { scale: 1, tx: 0, ty: 0 });
});
