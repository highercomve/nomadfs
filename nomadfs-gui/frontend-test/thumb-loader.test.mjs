import { test } from "node:test";
import assert from "node:assert/strict";
import { createThumbLoader } from "../frontend/thumb-loader.js";

// A clock and timers the test moves by hand.
function fakeTime() {
  let t = 0;
  const timers = [];
  return {
    now: () => t,
    setTimer: (fn, ms) => { const h = { at: t + ms, fn }; timers.push(h); return h; },
    clearTimer: (h) => { const i = timers.indexOf(h); if (i >= 0) timers.splice(i, 1); },
    async advance(ms) {
      t += ms;
      for (;;) {
        timers.sort((a, b) => a.at - b.at);
        if (!timers.length || timers[0].at > t) break;
        timers.shift().fn();
        await flush();
      }
      await flush();
    },
  };
}
const flush = () => new Promise((r) => setImmediate(r));

test("nearest the middle loads first, a few at a time", async () => {
  const time = fakeTime();
  const order = [];
  const loader = createThumbLoader({ ...time, concurrency: 2, load: async (key) => { order.push(key); return `${key}.jpg`; } });
  const got = [];
  loader.want("far", "u", (s) => got.push(s), 500);
  loader.want("near", "u", (s) => got.push(s), 10);
  loader.want("mid", "u", (s) => got.push(s), 100);
  await flush(); await flush();
  // "far" started at once (it asked first, alone); then the nearest.
  assert.deepEqual(order.slice(1), ["near", "mid"]);
  assert.deepEqual(got.sort(), ["far.jpg", "mid.jpg", "near.jpg"]);
});

test("a thumbnail not there yet is asked again, less often, while wanted", async () => {
  const time = fakeTime();
  let tries = 0;
  const loader = createThumbLoader({ ...time, minDelay: 1000, maxDelay: 4000, load: async () => (++tries >= 4 ? "ok.jpg" : null) });
  let src = null;
  loader.want("k", "u", (s) => { src = s; });
  await flush(); await flush();
  assert.equal(tries, 1);
  await time.advance(1000); assert.equal(tries, 2); // after 1 s
  await time.advance(1999); assert.equal(tries, 2); // then 2 s
  await time.advance(1); assert.equal(tries, 3);
  await time.advance(4000); assert.equal(tries, 4); // capped at 4 s
  assert.equal(src, "ok.jpg");
  assert.equal(loader.pending, 0);
  // Loaded once: a tile showing it again gets it at once.
  let again = null;
  loader.want("k", "u", (s) => { again = s; });
  assert.equal(again, "ok.jpg");
});

test("a tile scrolled away stops being asked for", async () => {
  const time = fakeTime();
  let tries = 0;
  const loader = createThumbLoader({ ...time, minDelay: 1000, load: async () => { tries++; return null; } });
  loader.want("k", "u", () => assert.fail("dropped"));
  await flush(); await flush();
  loader.drop("k");
  await time.advance(60000);
  assert.equal(tries, 1);
  assert.equal(loader.pending, 0);
});

test("kick asks again at once instead of at the next retry", async () => {
  const time = fakeTime();
  let tries = 0;
  const loader = createThumbLoader({ ...time, minDelay: 30000, load: async () => (++tries >= 2 ? "ok.jpg" : null) });
  let src = null;
  loader.want("k", "u", (s) => { src = s; });
  await flush(); await flush();
  assert.equal(tries, 1);
  loader.kick("k");
  await flush(); await flush();
  assert.equal(tries, 2);
  assert.equal(src, "ok.jpg");
});
