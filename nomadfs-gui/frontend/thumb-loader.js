// ---- Loading the Photos page's thumbnails in the background ----
//
// Tiles on screen ask first (nearest the middle of the view first), a few
// at a time; one whose thumbnail isn't there yet (the device that has the
// photo is still making it, or is busy) is asked again later, sooner at
// first and then less often, for as long as it stays on screen. A tile
// scrolled away leaves the queue. A key that loaded once answers at once.

/**
 * @param {object} o
 * @param {(key: string, url: string, attempt: number) => Promise<string|null>} o.load
 *   Loads one thumbnail; the URL it loaded (for the tile's <img>), or null.
 * @param {number} [o.concurrency] loads running at once
 * @param {number} [o.minDelay] ms before the first retry; doubles each time
 * @param {number} [o.maxDelay] ms between retries at most
 * @param {() => number} [o.now]
 * @param {(fn: () => void, ms: number) => any} [o.setTimer]
 * @param {(t: any) => void} [o.clearTimer]
 */
export function createThumbLoader({
  load,
  concurrency = 6,
  minDelay = 1000,
  maxDelay = 30000,
  now = () => Date.now(),
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = (t) => clearTimeout(t),
}) {
  /** key → { url, onLoaded, priority, attempts, due, running } */
  const jobs = new Map();
  /** key → the URL that loaded */
  const loaded = new Map();
  let running = 0;
  let timer = null;
  let timerAt = Infinity;

  function want(key, url, onLoaded, priority = 0) {
    const done = loaded.get(key);
    if (done) return onLoaded(done);
    const job = jobs.get(key);
    if (job) {
      job.onLoaded = onLoaded;
      job.priority = priority;
    } else {
      jobs.set(key, { url, onLoaded, priority, attempts: 0, due: 0, running: false });
    }
    pump();
  }

  /** The tile showing `key` went away: stop asking for it. */
  function drop(key) {
    const job = jobs.get(key);
    if (job && !job.running) jobs.delete(key);
    else if (job) job.onLoaded = null; // finishes, then is forgotten
  }

  function setPriority(key, priority) {
    const job = jobs.get(key);
    if (job) job.priority = priority;
  }

  function pump() {
    if (running >= concurrency) return;
    const t = now();
    const ready = [];
    let next = Infinity;
    for (const [key, job] of jobs) {
      if (job.running) continue;
      if (job.due <= t) ready.push([key, job]);
      else next = Math.min(next, job.due);
    }
    ready.sort((a, b) => a[1].priority - b[1].priority);
    for (const [key, job] of ready) {
      if (running >= concurrency) break;
      start(key, job);
    }
    arm(next);
  }

  /** Wakes the queue when the earliest retry is due. */
  function arm(at) {
    if (at === Infinity || at >= timerAt) return;
    if (timer !== null) clearTimer(timer);
    timerAt = at;
    timer = setTimer(() => {
      timer = null;
      timerAt = Infinity;
      pump();
    }, Math.max(0, at - now()));
  }

  function start(key, job) {
    job.running = true;
    running += 1;
    const attempt = job.attempts;
    Promise.resolve()
      .then(() => load(key, job.url, attempt))
      .catch(() => null)
      .then((src) => {
        running -= 1;
        job.running = false;
        if (src) {
          loaded.set(key, src);
          jobs.delete(key);
          job.onLoaded?.(src);
        } else if (!job.onLoaded) {
          jobs.delete(key); // dropped while loading
        } else {
          job.attempts += 1;
          job.due = now() + Math.min(maxDelay, minDelay * 2 ** (job.attempts - 1));
        }
        pump();
      });
  }

  /** Ask again now for `key` (its data just arrived here), not at its
   *  next retry. */
  function kick(key) {
    const job = jobs.get(key);
    if (job && !job.running) job.due = 0;
    pump();
  }

  /** Ask again now for everything still waiting. */
  function kickAll() {
    for (const job of jobs.values()) if (!job.running) job.due = 0;
    pump();
  }

  /** Forget what loaded (the folder's thumbnails may be new): a new index. */
  function reset() {
    jobs.clear();
    loaded.clear();
    if (timer !== null) clearTimer(timer);
    timer = null;
    timerAt = Infinity;
  }

  return { want, drop, setPriority, kick, kickAll, reset, get pending() { return jobs.size; }, get running() { return running; } };
}

/**
 * Loads `url` as an image off-screen; the URL when it loaded, else null.
 * A retry adds `?a=<n>` so the browser asks again instead of reusing the
 * failed answer.
 */
export function loadImage(url, attempt) {
  return new Promise((resolve) => {
    const src = attempt > 0 ? `${url}?a=${attempt}` : url;
    const img = new Image();
    img.decoding = "async";
    img.onload = () => resolve(src);
    img.onerror = () => resolve(null);
    img.src = src;
  });
}
