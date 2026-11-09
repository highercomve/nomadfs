// ---- Back (Android's back button and gesture, a mouse's back button) ----

// Back goes up one level from wherever the app is: closes the open file or
// the More sheet, then the parent folder, then Browse; at the top it's
// Android's (the app goes to the background). The WebView's Back follows
// the page history, so the page keeps one history entry per level it can
// go up. They're added as the app goes deeper, right after the tap that
// took it there: the WebView skips entries a page adds on its own.

// Each feature that can go up registers one provider:
// { depth(): how many up-levels it can absorb now, up(): absorb one }.
// Registration order is priority: providers register in the order
// Back reads them (menu, preview, More sheet, notes, swarm, browse).
const providers = [];

/** `provider`: { depth(): levels, up(): do one }. */
export function registerUp(provider) {
  providers.push(provider);
}

export function upLevels() {
  return providers.reduce((n, p) => n + p.depth(), 0);
}

/** Where the next Back press goes: the first provider that can absorb it. */
function upTarget() {
  for (const p of providers) {
    if (p.depth() > 0) return () => p.up();
  }
  return null;
}

let backDepth = 0; // our history entries above the page's own
let ignorePops = 0; // history.go() calls of ours still to arrive

/** Matches the history entries to the levels after any move. */
export function syncBack() {
  const want = upLevels();
  while (backDepth < want) history.pushState({ nomadfsBack: ++backDepth }, "");
  if (backDepth > want) {
    // Went up through the app (a breadcrumb, the close button).
    ignorePops++;
    const n = backDepth - want;
    backDepth = want;
    history.go(-n);
  }
}

/** The popstate listener is installed once, from app.js. */
export function installBack() {
  window.addEventListener("popstate", () => {
    if (ignorePops > 0) { ignorePops--; return; }
    backDepth = Math.max(0, backDepth - 1);
    upTarget()?.();
    syncBack();
  });
}
