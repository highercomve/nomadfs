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

## Layout

| Path | What |
|---|---|
| `src/main.zig` | The Zig side: `Commands` the page can call and `Events` pushed to it |
| `frontend/` | The page: plain HTML + JavaScript (no build step) |
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
