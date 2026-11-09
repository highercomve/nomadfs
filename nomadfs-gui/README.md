# Nomadfs Gui

A desktop app built with [Oriel](https://github.com/highercomve/Oriel): Zig
and the system webview (WebKitGTK on Linux, WebView2 on Windows, WKWebView on macOS), with a plain HTML + JavaScript (no build step)
frontend.

## Develop

```sh
oriel build      # build zig-out/bin/nomadfs-gui with frontend/ embedded
oriel run        # build and run it (rerun after editing frontend/)
oriel check      # type-check the Zig code (fast)
oriel package    # deb/rpm/AppImage, setup.exe or .app/.dmg in zig-out/package/
```

Each command is a thin wrapper around `zig build <step>` (run from anywhere
inside the project; extra arguments are passed on), so plain `zig build ...`
works as well. `oriel doctor` checks that the system has everything needed.

### Development build and `oriel agent`

```sh
oriel dev        # zig build dev: serves frontend/ on 127.0.0.1:5180 and runs nomadfs-gui-dev
```

The development build loads the page from that file server (a page edit is a
reload) and answers `oriel agent` on a control socket, so a script or a coding
agent can check the app without the mouse or the desktop:

```sh
oriel agent snapshot --interactive         # the page as an outline with refs
oriel agent click "text=Swarm folder"
oriel agent eval "document.getElementById('pv-name').textContent"
oriel agent screenshot                     # the web view (not native views over it)
oriel agent logs                           # the page's console and the app's log
```

`claude mcp add oriel -- oriel agent mcp` offers the same commands as MCP
tools. The native video player (GtkVideo) draws over the page, so a
screenshot from the agent shows it black; capture the window itself to see
it. Only one copy of the app runs per user: quit the installed one first.
Packages never contain the agent (`oriel package` refuses a dev binary).

## Layout

| Path | What |
|---|---|
| `src/main.zig` | The Zig side: `Commands` the page can call and `Events` pushed to it |
| `frontend/` | The page: plain HTML + JavaScript (no build step). `notes.js` is the Notes screen, `markdown.js` its renderer, `notes-model.js` what the list decides |
| `frontend-test/` | Node tests of the page's logic: `zig build test-frontend` (needs `node`) |
| `build.zig` | Which Oriel modules are compiled in, packaging metadata |
| `build.zig.zon` | Package manifest; Oriel is a dependency |
| `src/android/` (optional) | App-owned Kotlin/Java helpers and Android platform hooks (`OrielAndroidHooks`) |
| `android/` (generated for Android builds) | Gradle project and Oriel runtime |

## Calling Zig from the page

```js
// window.oriel is injected into the page by Oriel.
const text = await window.oriel.invoke("greet", { name: "Ada" });
const off = window.oriel.listen("greeted", (e) => console.log(e.count));
```

A command is any `pub fn` in `Commands`; its arguments struct and return type
become the JSON on the JavaScript side. Events declared in `Events` are sent
with `events.emit(.name, payload)` from any thread.

## Android platform hooks

To react to the Android Activity and WebView (or take over a file chooser),
keep Kotlin or Java implementations in your own sources and register them in
`build.zig`:

```zig
.android = .{
    .hooks = &.{.{
        .class = "dev.example.MyHooks",
        .sources = &.{b.path("src/android/MyHooks.kt")},
    }},
},
```

The class implements `dev.oriel.OrielAndroidHooks` and needs a public
zero-argument constructor. Oriel generates `OrielHooksRegistry.kt` on each
Android build to dispatch lifecycle, WebView, native-result, permission, and
file-picker hooks. Edit your source and build configuration to change behavior.
`.dependencies` on the hook (or `.android.dependencies`) adds pinned Maven
SDKs, and `.android.proguard_rules` adds R8 rules for JNI calls.

See [Platform hooks](https://oriel.foreachdeveloper.com/docs/platform-hooks/)
for a complete implementation and request-code allocation.
