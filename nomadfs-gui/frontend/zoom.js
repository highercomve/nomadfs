// ---- Zooming a photo in the viewer ----
//
// Pinch with two fingers, the + and − buttons or keys, Ctrl or Shift with
// the wheel (a trackpad pinch arrives as Ctrl + wheel), or a double click / double tap.
// Zoomed in, dragging moves around the photo (the viewer's swipe to the
// next file waits until it is back at 1×). Each new photo starts at 1×.

export const MIN_SCALE = 1;
export const MAX_SCALE = 8;
/** One + or − press, or one wheel notch with Shift. */
export const STEP = 1.5;

/** The view of one photo: scale and offset (px) from where it sits at 1×. */
export function initial() {
  return { scale: 1, tx: 0, ty: 0 };
}

/**
 * `view` scaled by `factor` keeping the screen point (px, py) still.
 * (px, py) is relative to the photo's centre at 1×; `w`×`h` is its size
 * at 1×. The scale is clamped to MIN..MAX and the offset so the photo
 * never leaves the frame.
 */
export function zoomAt(view, factor, px, py, w, h) {
  const scale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, view.scale * factor));
  const k = scale / view.scale;
  // A point u (from the centre, unscaled) shows at t + s·u; keep p fixed.
  const tx = px - k * (px - view.tx);
  const ty = py - k * (py - view.ty);
  return clamp({ scale, tx, ty }, w, h);
}

/** `view` moved by (dx, dy), kept inside the frame. */
export function pan(view, dx, dy, w, h) {
  return clamp({ scale: view.scale, tx: view.tx + dx, ty: view.ty + dy }, w, h);
}

/** At 1× the photo is centred; zoomed, its edges can't pass the frame's. */
export function clamp(view, w, h) {
  const mx = ((view.scale - 1) * w) / 2;
  const my = ((view.scale - 1) * h) / 2;
  return {
    scale: view.scale,
    // (+ 0 turns -0 into 0)
    tx: Math.min(mx, Math.max(-mx, view.tx)) + 0,
    ty: Math.min(my, Math.max(-my, view.ty)) + 0,
  };
}

export function isZoomed(view) {
  return view.scale > 1.001;
}

// ---- The viewer's photo ----

let img = null;
let view = initial();
const pointers = new Map(); // pointerId → {x, y}
let pinch = null; // {dist, mx, my}
let lastTap = 0;
let onChange = () => {};

/** Whether the photo on screen is zoomed in (the swipe handler asks). */
export function zoomed() {
  return img !== null && isZoomed(view);
}

/** The viewer shows `el` (an <img>, or null for anything else). */
export function attachZoom(el) {
  img = el;
  view = initial();
  pointers.clear();
  pinch = null;
  if (img) img.style.transform = "";
  onChange(!!img, false);
}

/** + and − in the viewer's bar; `factor` > 1 zooms in. */
export function zoomBy(factor) {
  if (!img) return;
  apply(zoomAt(view, factor, 0, 0, img.clientWidth, img.clientHeight));
}

export function resetZoom() {
  if (img) apply(initial());
}

/** Called with (zoomable, zoomed) whenever either changes. */
export function onZoomChange(fn) {
  onChange = fn;
}

function apply(next) {
  view = next;
  img.style.transform = isZoomed(view) ? `translate(${view.tx}px, ${view.ty}px) scale(${view.scale})` : "";
  img.classList.toggle("zoomed", isZoomed(view));
  onChange(true, isZoomed(view));
}

/** (x, y) on screen relative to the photo's centre at 1×. */
function fromCentre(x, y) {
  const r = img.getBoundingClientRect(); // includes the current transform
  return { px: x - (r.left + r.width / 2) + view.tx, py: y - (r.top + r.height / 2) + view.ty };
}

/** Wires the gestures on the viewer's body once. */
export function installZoom(body) {
  body.addEventListener("wheel", (e) => {
    if (!img || !(e.shiftKey || e.ctrlKey)) return;
    e.preventDefault();
    // Shift turns a vertical wheel into deltaX on some systems.
    const delta = e.deltaY || e.deltaX;
    // A trackpad pinch (Ctrl) sends small deltas: zoom smoothly. A mouse
    // notch (~100) would jump; never more than one button step per event.
    const factor = Math.min(STEP, Math.max(1 / STEP, Math.exp(-delta / 100)));
    const { px, py } = fromCentre(e.clientX, e.clientY);
    apply(zoomAt(view, factor, px, py, img.clientWidth, img.clientHeight));
  }, { passive: false });

  body.addEventListener("dblclick", (e) => {
    if (!img || e.target !== img) return;
    toggleAt(e.clientX, e.clientY);
  });

  body.addEventListener("pointerdown", (e) => {
    if (!img || e.target !== img) return;
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    img.setPointerCapture?.(e.pointerId);
    if (pointers.size === 2) pinch = pinchState();
    // A double tap (touch has no dblclick in every WebView).
    if (e.pointerType !== "mouse" && pointers.size === 1) {
      const now = performance.now();
      if (now - lastTap < 300) {
        lastTap = 0;
        toggleAt(e.clientX, e.clientY);
      } else lastTap = now;
    }
  });

  body.addEventListener("pointermove", (e) => {
    const p = pointers.get(e.pointerId);
    if (!img || !p) return;
    const dx = e.clientX - p.x;
    const dy = e.clientY - p.y;
    p.x = e.clientX;
    p.y = e.clientY;
    if (pinch && pointers.size >= 2) {
      const now = pinchState();
      const { px, py } = fromCentre(now.mx, now.my);
      let next = zoomAt(view, now.dist / pinch.dist, px, py, img.clientWidth, img.clientHeight);
      next = pan(next, now.mx - pinch.mx, now.my - pinch.my, img.clientWidth, img.clientHeight);
      pinch = now;
      apply(next);
    } else if (isZoomed(view)) {
      apply(pan(view, dx, dy, img.clientWidth, img.clientHeight));
    }
  });

  const end = (e) => {
    pointers.delete(e.pointerId);
    if (pointers.size < 2) pinch = null;
  };
  body.addEventListener("pointerup", end);
  body.addEventListener("pointercancel", end);
}

function toggleAt(x, y) {
  if (isZoomed(view)) return apply(initial());
  const { px, py } = fromCentre(x, y);
  apply(zoomAt(view, 2.5, px, py, img.clientWidth, img.clientHeight));
}

function pinchState() {
  const [a, b] = [...pointers.values()];
  return { dist: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
}

/** Whether two fingers are on the photo (a pinch, not a swipe). */
export function pinching() {
  return pointers.size >= 2;
}
