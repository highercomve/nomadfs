//! Fixed WebDAV credentials. Only a salted Argon2id hash reaches disk.
const std = @import("std");
const Config = @import("../config.zig").Config.WebDavConfig;
const argon2 = std.crypto.pwhash.argon2;
// This on-disk format fixes Argon2id v19 to 19 MiB, two passes, one lane.
// A future parameter change needs a new format prefix.
const params: argon2.Params = .{ .t = 2, .m = 19 * 1024, .p = 1 };
pub const hash_len = 106;

pub fn validate(cfg: Config) !void {
    if (cfg.user.len == 0 and cfg.password_hash.len == 0) return;
    if (cfg.user.len == 0 or cfg.user.len > 128 or std.mem.indexOfAny(u8, cfg.user, ":\"\r\n\x00") != null) return error.InvalidWebDavUser;
    const h = cfg.password_hash;
    if (h.len != hash_len or !std.mem.startsWith(u8, h, "argon2id:") or h[41] != ':') return error.InvalidWebDavHash;
    for (h[9..41]) |c| if (!std.ascii.isHex(c)) return error.InvalidWebDavHash;
    for (h[42..]) |c| if (!std.ascii.isHex(c)) return error.InvalidWebDavHash;
}

pub fn hash(a: std.mem.Allocator, password: []const u8, out: *[hash_len]u8) ![]const u8 {
    if (password.len == 0 or password.len > 1024) return error.InvalidWebDavPassword;
    const io = std.Io.Threaded.global_single_threaded.io();
    var salt: [16]u8 = undefined;
    try io.randomSecure(&salt);
    var digest: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &digest);
    try argon2.kdf(a, &digest, password, &salt, params, .argon2id, io);
    return std.fmt.bufPrint(out, "argon2id:{s}:{s}", .{ std.fmt.bytesToHex(salt, .lower), std.fmt.bytesToHex(digest, .lower) });
}

pub fn verify(a: std.mem.Allocator, cfg: Config, header: ?[]const u8) bool {
    validate(cfg) catch return false;
    if (!cfg.hasLogin()) return false;
    const h = header orelse return false;
    if (h.len < 6 or !std.ascii.eqlIgnoreCase(h[0..6], "Basic ")) return false;
    const encoded = h[6..];
    const decoder = std.base64.standard.Decoder;
    const n = decoder.calcSizeForSlice(encoded) catch return false;
    var decoded: [128 + 1 + 1024]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    if (n > decoded.len) return false;
    decoder.decode(decoded[0..n], encoded) catch return false;
    const colon = std.mem.indexOfScalar(u8, decoded[0..n], ':') orelse return false;
    // Hash even when the username differs.
    var salt: [16]u8 = undefined;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&salt, cfg.password_hash[9..41]) catch return false;
    _ = std.fmt.hexToBytes(&expected, cfg.password_hash[42..]) catch return false;
    var actual: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &actual);
    argon2.kdf(a, &actual, decoded[colon + 1 .. n], &salt, params, .argon2id, std.Io.Threaded.global_single_threaded.io()) catch return false;
    const password_ok = std.crypto.timing_safe.eql([32]u8, actual, expected);
    var given_user: [32]u8 = undefined;
    var expected_user: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded[0..colon], &given_user, .{});
    std.crypto.hash.sha2.Sha256.hash(cfg.user, &expected_user, .{});
    const user_ok = std.crypto.timing_safe.eql([32]u8, given_user, expected_user);
    return password_ok and user_ok;
}

test "webdav login: salted hashing and Basic verification" {
    const a = std.testing.allocator;
    var first: [hash_len]u8 = undefined;
    var second: [hash_len]u8 = undefined;
    const cfg: Config = .{ .user = "user", .password_hash = try hash(a, "pass", &first) };
    try validate(cfg);
    try std.testing.expect(!std.mem.eql(u8, cfg.password_hash, try hash(a, "pass", &second)));
    try std.testing.expect(verify(a, cfg, "Basic dXNlcjpwYXNz"));
    try std.testing.expect(!verify(a, cfg, "Basic dXNlcjp3cm9uZw=="));
    try std.testing.expect(!verify(a, cfg, null));
}
