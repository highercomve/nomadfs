const std = @import("std");
const nomadfs = @import("nomadfs");

pub fn run(io: std.Io, a: std.mem.Allocator, args: []const []const u8) !void {
    const usage = "nomadfs webdav-login set <user> [--config FILE] (password on stdin)\nnomadfs webdav-login clear [--config FILE]\n";
    if (args.len == 0) {
        std.debug.print("{s}", .{usage});
        return error.InvalidArguments;
    }
    const clear = std.mem.eql(u8, args[0], "clear");
    if (!clear and (!std.mem.eql(u8, args[0], "set") or args.len < 2)) return error.InvalidArguments;
    const start: usize = if (clear) 1 else 2;
    var path: ?[]const u8 = null;
    if (args.len != start) {
        if (args.len != start + 2 or !std.mem.eql(u8, args[start], "--config")) return error.InvalidArguments;
        path = args[start + 1];
    }
    const owned = if (path == null) try nomadfs.config.findConfigPath(a) else null;
    defer if (owned) |p| a.free(p);
    const config_path = path orelse owned.?;
    var cfg = try nomadfs.config.parseConfig(a, config_path);
    defer cfg.deinit(a);
    var value = cfg.webdav;
    var hash_buf: [106]u8 = undefined;
    if (clear) {
        value.user = "";
        value.password_hash = "";
    } else {
        var password: [1026]u8 = undefined;
        defer std.crypto.secureZero(u8, &password);
        var read_buf: [128]u8 = undefined;
        defer std.crypto.secureZero(u8, &read_buf);
        var input = std.Io.File.stdin().readerStreaming(io, &read_buf);
        const n = try input.interface.readSliceShort(&password);
        if (n == password.len) return error.InvalidWebDavPassword;
        value.user = args[1];
        value.password_hash = try nomadfs.webdav_login.hash(a, std.mem.trimEnd(u8, password[0..n], "\r\n"), &hash_buf);
    }
    try nomadfs.config_file.setWebDav(a, config_path, value);
    std.debug.print("WebDAV login saved. Restart the node to apply it.\n", .{});
}
