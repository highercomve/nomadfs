const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    // On macOS, a target without a version builds for macOS 13+ (not just
    // the Mac building it); pass this target to every executable you add.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});

    // Oriel's built-in modules and plugins. Switch on what the app uses:
    // anything left off is neither compiled nor linked. Say it once for
    // every target: where a module doesn't exist (a tray on phones),
    // `oriel.tray.available` is false, so guard its calls with
    // `if (oriel.tray.available)`.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .tray = false,
        .menu = false,
        .store = false,
        .dialog = true, // native folder picker for shared folders
        .notification = false,
        .updater = false,
        .sql = false,
        .fs_watch = false,
        .media_server = false,
        .global_shortcut = false,
        .input = false,
        .clipboard = false,
    });

    // Frontend in frontend/ (embeds frontend/ as-is).
    // zig build          production build
    // zig build run      run it
    // zig build check    type-check src/ without building
    // zig build package  installers: deb/rpm/AppImage (Linux), setup.exe (Windows), .app/.dmg (macOS)
    // The NomadFS core, shared with the CLI and mobile bindings.
    const nomadfs_mod = b.createModule(.{
        .root_source_file = b.path("../src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = oriel.addApp(b, dep, .{
        .name = "nomadfs-gui",
        .imports = &.{
            .{ .name = "nomadfs", .module = nomadfs_mod },
        },
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .frontend = .{
            // A static page: embedded as-is, no npm and no dev server.
            .dir = "frontend",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "net.nomadfs.app",
            .name = "NomadFS",
            // .publisher = "Your Name <you@example.com>", // default: from the app id
            .summary = "Share folders across your devices; files download on demand",
            .version = "0.1.0",
        },
        // The page's camera scans invite QR codes (getUserMedia).
        .permissions = .{ .camera = "Scan invite QR codes from your other devices" },
        .android = .{
            // Sharing folders like DCIM/Camera and saving to Download/:
            // "All files access", granted from the system settings page the
            // storage extension opens.
            .permissions = &.{
                .{ .name = "android.permission.MANAGE_EXTERNAL_STORAGE" },
                .{ .name = "android.permission.READ_EXTERNAL_STORAGE", .max_sdk = 32 },
                .{ .name = "android.permission.WRITE_EXTERNAL_STORAGE", .max_sdk = 29 },
            },
        },
        .extensions = &.{.{
            .name = "nomadfs.storage",
            .android = .{
                .class = "net.nomadfs.app.StorageExtension",
                .sources = &.{b.path("android-src/StorageExtension.kt")},
            },
        }},
        // The isolation pattern: every call from the frontend to Zig goes
        // through isolation/hook.js first, in a frame the page can't reach.
        // .isolation = .{ .hook = b.path("isolation/hook.js") },
    });

    // zig build test: runs the commands tests with the same imports the
    // app exe gets (nomadfs core + oriel paths).
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nomadfs", .module = nomadfs_mod },
        },
    });
    const app_test = b.addTest(.{ .root_module = test_mod });
    const run_test = b.addRunArtifact(app_test);
    const test_step = b.step("test", "Run the GUI command tests");
    test_step.dependOn(&run_test.step);
}
