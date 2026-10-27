// `window.oriel` is injected by Oriel: `invoke()` talks typed Zig.
const { invoke } = window.oriel;

const $ = (id) => document.getElementById(id);

let configPath = `${(navigator && navigator.platform) === "Win32" ? "C:" : ""}`; // refined by Zig's HOME
const homePrefix = "/"; // refined by the first ensure_config result

async function refreshState() {
  const state = await invoke("app_info", null);
  $("info").textContent = `Zig ${state.zig} · ${state.mode} · ${state.dev ? "dev" : "release"}`;
}

async function nodeState() {
  try {
    const state = await invoke("node_state", null);
    $("node-state").textContent = state.running
      ? `running · device ${state.device_id.slice(0, 12)}…`
      : "not running";
    $("open-node").disabled = state.running;
    $("close-node").disabled = !state.running;
  } catch {
    $("node-state").textContent = "state unknown";
  }
}

$("open-node").addEventListener("click", async () => {
  $("node-state").textContent = "opening…";
  try {
    const cfg = await invoke("ensure_config", null);
    await invoke("node_open", { config_path: cfg.path });
    $("node-state").textContent = "running";
  } catch (err) {
    $("node-state").textContent = `open failed: ${err}`;
  }
  nodeState();
});

$("close-node").addEventListener("click", async () => {
  try { await invoke("node_close", null); } catch {}
  nodeState();
});

$("put-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("text-in").value;
  if (!text) return;
  try {
    const cid = await invoke("put_text", { text });
    $("cid-output").textContent = `CID: ${cid}`;
    $("node-state").textContent = `stored · ${$("text-in").value.length} bytes`;
  } catch (err) {
    $("cid-output").textContent = `store failed: ${err}`;
  }
});

$("fetch").addEventListener("click", async () => {
  const cid = $("cid-in").value.trim();
  if (cid.length !== 64) return;
  try {
    const text = await invoke("get_text", { cid });
    $("text-out").textContent = text;
  } catch (err) {
    $("text-out").textContent = `fetch failed: ${err}`;
  }
});

$("devices-refresh").addEventListener("click", async () => {
  try {
    const cfg = await invoke("ensure_config", null);
    const devices = await invoke("devices_list", { config_path: cfg.path });
    $("devices-list").innerHTML = "";
    if (!devices.length) {
      const li = document.createElement("li");
      li.textContent = "no trusted devices yet";
      $("devices-list").appendChild(li);
      return;
    }
    for (const d of devices) {
      const li = document.createElement("li");
      li.textContent = `${d.fingerprint}  ${d.label}  added ${d.added_at}`;
      $("devices-list").appendChild(li);
    }
  } catch (err) {
    $("devices-list").innerHTML = `<li>devices failed: ${err}</li>`;
  }
});

refreshState();
nodeState();
