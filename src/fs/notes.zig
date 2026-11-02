//! Notes are Markdown files in the swarm folder's `Notes/` path. This
//! service owns what a note means: the title is the file name, a notebook is
//! a folder, a save is a compare-and-set against the content the editor
//! loaded, conflicts are resolved here, and pins belong to the device. Front
//! ends (the app, later the command line and the mobile API) parse arguments
//! and call it. The node owns the one service of a device (node.zig).
//!
//! The bytes and the listing are the swarm folder's (swarm.zig); how they
//! reach other devices is the cluster's. Nothing here talks to the network
//! except `read`, which goes through `SwarmFolder.readAt` like any file.

const std = @import("std");
const sync = @import("../sync.zig");
const SwarmFolder = @import("swarm.zig").SwarmFolder;
const manifest_mod = @import("manifest.zig");

const Allocator = std.mem.Allocator;

/// A note is at most this many bytes (the app's limit for text before notes
/// had their own service).
pub const max_note_bytes = 8 * 1024 * 1024;
/// Titles (and notebook names) are cut at this many bytes, on a character
/// boundary.
pub const max_title_bytes = 120;
/// Pins kept per device.
pub const max_pins = 500;
/// Bodies of notes larger than this aren't searched.
const max_searched_bytes = 1024 * 1024;
/// One search reads at most this many bytes of note text in all.
const max_search_bytes = 64 * 1024 * 1024;
/// The pins file: a line per pin, `<path>\t<cid hex>`.
const max_pins_file = max_pins * (manifest_mod.max_path_len + 66) + 1;

const prefix = "Notes/";

/// Functions that return a `Note` (or a list of them) allocate it in the
/// allocator they are given: pass an arena and free it whole.
pub const Notes = struct {
    folder: *SwarmFolder,
    allocator: Allocator,
    /// One line per pin: the note's path.
    pins_path: []u8,
    /// Serialises the pins file. Taken before the folder's own lock.
    pins_mutex: sync.Mutex = .{},
    /// Who is told when a sync changed the notes (see `subscribe`).
    hooks_mutex: sync.Mutex = .{},
    observers: SwarmFolder.HookList = .{},
    /// The Notes/ digest observers were last told about.
    seen_digest: [32]u8,
    /// The Notes/ digest at the end of the last legacy-rename pass. Only the
    /// folder's thread (after-sync hook) touches it.
    migrated_digest: ?[32]u8 = null,

    pub const root = "Notes";

    pub const Note = struct {
        /// "Notes/Work/Standup.md"
        path: []const u8,
        /// "Standup": the file name without its extension (a legacy note
        /// without the date prefix).
        title: []const u8,
        /// "Work"; "" for the top; "Work/Ideas" for deeper folders.
        notebook: []const u8,
        cid: [32]u8,
        size: u64,
        mtime: u64,
        /// Device name of the last edit, and its ID.
        author: []const u8,
        author_id: [32]u8,
        pinned: bool = false,
        /// Set on a conflict copy ("Ideas (conflict from Desk).md"): the path
        /// of the note it is a copy of, when that note exists.
        conflict_of: ?[]const u8 = null,
        /// "YYYY-MM-DD HH-MM-SS title.txt", written before notes had titles.
        legacy: bool = false,
        /// A note the editor opens (.md and .txt); anything else in Notes/
        /// is a file for the regular viewer.
        editable: bool = true,
    };

    pub const Hit = struct { path: []const u8, title: []const u8, snippet: []const u8 };

    /// What a delete leaves for an undo.
    pub const Removed = struct { path: []const u8, cid: [32]u8, size: u64, author_id: [32]u8, pinned: bool };

    /// The answer to a save or rename: `changed` when the note is no longer
    /// the one the editor had (nothing was stored); `note` is then the
    /// current one, or null if it is gone.
    pub const Outcome = struct { changed: bool, note: ?Note };

    /// A note and the content the editor saw of it.
    pub const Ref = struct { path: []const u8, cid: [32]u8 };

    pub const Resolution = enum { use_copy, append, discard };

    pub const Resolved = struct {
        outcome: Outcome,
        /// The conflict copy as it was deleted (for an undo); null when the
        /// copy could not be deleted (the note is merged all the same).
        removed: ?Removed,
    };

    /// Text shared into the app: the subject or file name makes the title,
    /// else the first line.
    pub const Share = struct { text: []const u8 = "", url: []const u8 = "", subject: []const u8 = "", name: []const u8 = "" };

    pub fn init(allocator: Allocator, folder: *SwarmFolder, pins_path: []const u8) !Notes {
        return .{
            .folder = folder,
            .allocator = allocator,
            .pins_path = try allocator.dupe(u8, pins_path),
            .seen_digest = folder.digestUnder(prefix),
        };
    }

    pub fn deinit(self: *Notes) void {
        self.allocator.free(self.pins_path);
    }

    /// Hooks the service into the folder's sync rounds: observers hear of
    /// changes under Notes/, and legacy notes this device wrote are renamed
    /// after the first round and when notes changed. Call once, before the
    /// folder starts.
    pub fn attach(self: *Notes) !void {
        try self.folder.addChangeHook(.{ .ctx = self, .runFn = onFolderChanged });
        try self.folder.addAfterSyncHook(.{ .ctx = self, .runFn = onAfterSync });
    }

    /// Runs `hook` (on the folder's thread, outside its locks) after a sync
    /// round that changed what is under Notes/. The hook must not outlive
    /// the service.
    pub fn subscribe(self: *Notes, hook: SwarmFolder.Hook) !void {
        self.hooks_mutex.lock();
        defer self.hooks_mutex.unlock();
        if (self.observers.len >= SwarmFolder.HookList.max_hooks) return error.TooManyHooks;
        self.observers.items[self.observers.len] = hook;
        self.observers.len += 1;
    }

    /// Whether what is under Notes/ differs from the digest in `seen`; when
    /// it does, `seen` is updated to the current one.
    pub fn changedSince(self: *Notes, seen: *[32]u8) bool {
        const now = self.folder.digestUnder(prefix);
        if (std.mem.eql(u8, &now, seen)) return false;
        seen.* = now;
        return true;
    }

    fn onFolderChanged(ctx: *anyopaque) void {
        const self: *Notes = @ptrCast(@alignCast(ctx));
        const observers = blk: {
            self.hooks_mutex.lock();
            defer self.hooks_mutex.unlock();
            if (!self.changedSince(&self.seen_digest)) return;
            break :blk self.observers;
        };
        observers.run();
    }

    fn onAfterSync(ctx: *anyopaque) void {
        const self: *Notes = @ptrCast(@alignCast(ctx));
        self.migrateIfNeeded();
    }

    // ---- Reading ----

    /// Every note and file under `Notes/`, pinned first, then newest first.
    /// A pin whose note was moved elsewhere follows it; one whose note was
    /// deleted is dropped. One pass over the manifest. Allocated in `arena`.
    pub fn list(self: *Notes, arena: Allocator) ![]Note {
        var found: std.ArrayList(Note) = .empty;
        for (try self.folder.listUnder(arena, root)) |item| {
            if (!std.unicode.utf8ValidateSlice(item.path)) continue;
            try found.append(arena, noteOf(item));
        }
        const notes = found.items;
        var index: std.StringHashMapUnmanaged(usize) = .empty;
        try index.ensureTotalCapacity(arena, @intCast(notes.len));
        for (notes, 0..) |n, i| index.putAssumeCapacity(n.path, i);
        for (notes) |*n| n.conflict_of = conflictBase(notes, &index, n.*);

        // Pins decorate the list: a pins file that can't be read or written
        // is logged and the list goes on without them.
        self.pins_mutex.lock();
        defer self.pins_mutex.unlock();
        if (self.loadPins(arena)) |pins| {
            const reconciled = try self.reconcilePins(arena, pins, notes, &index);
            if (reconciled.changed) self.storePins(reconciled.pins) catch |err| std.debug.print("notes: saving the pins failed: {any}\n", .{err});
            for (notes) |*n| n.pinned = n.editable and pinIndex(reconciled.pins, n.path) != null;
        } else |err| std.debug.print("notes: reading the pins failed: {any}\n", .{err});

        std.mem.sort(Note, notes, {}, newerFirst);
        return notes;
    }

    /// One note by path, or error.FileNotFound.
    pub fn get(self: *Notes, arena: Allocator, path: []const u8) !Note {
        try requireNote(path);
        const item = try self.folder.fileItem(arena, path) orelse return error.FileNotFound;
        var note = noteOf(item);
        note.conflict_of = try self.conflictBaseOf(arena, note);
        self.pins_mutex.lock();
        defer self.pins_mutex.unlock();
        if (note.editable) {
            if (self.loadPins(arena)) |pins| {
                note.pinned = pinIndex(pins, note.path) != null;
            } else |err| std.debug.print("notes: reading the pins failed: {any}\n", .{err});
        }
        return note;
    }

    /// The note a conflict copy is a copy of, if it exists (`list` finds it
    /// in the listing it already has).
    fn conflictBaseOf(self: *Notes, arena: Allocator, copy: Note) !?[]const u8 {
        var buf: [manifest_mod.max_path_len]u8 = undefined;
        const base = conflictBasePath(&buf, copy) orelse return null;
        const item = try self.folder.fileItem(arena, base) orelse return null;
        return if (noteOf(item).editable) item.path else null;
    }

    /// The distinct notebooks that hold a note, sorted. A notebook with
    /// nothing in it doesn't exist; files that aren't notes don't make one.
    pub fn notebooks(self: *Notes, arena: Allocator) ![][]const u8 {
        return notebooksOf(arena, try self.list(arena));
    }

    /// A note's text and the CID the editor must pass back to `save`. Reads
    /// this device's blocks first; a note whose author is offline is fetched
    /// from a backup device, like any file in the swarm folder. A file that
    /// isn't UTF-8 is error.NotText.
    pub fn read(self: *Notes, gpa: Allocator, path: []const u8) !struct { text: []u8, cid: [32]u8 } {
        try requireNote(path);
        const info = self.folder.fileInfo(path) orelse return error.FileNotFound;
        const text = try self.readContent(gpa, info.cid, info.size, info.author, true);
        errdefer gpa.free(text);
        if (!std.unicode.utf8ValidateSlice(text)) return error.NotText;
        return .{ .text = text, .cid = info.cid };
    }

    /// The start of the text as a one-line preview (about 160 characters,
    /// blank lines skipped), or null when its blocks aren't on this device:
    /// listing never waits on the network.
    pub fn snippet(self: *Notes, arena: Allocator, note: Note) !?[]const u8 {
        if (!note.editable) return null;
        if (note.size == 0) return "";
        var buf: [768]u8 = undefined;
        const n = self.folder.readLocal(arena, note.cid, 0, &buf) catch return null;
        return try previewOf(arena, validPrefix(buf[0..n]), 160);
    }

    /// Notes whose title contains `query` (any case), then notes whose text
    /// does, among the ones this device holds. At most `limit` hits. The
    /// text of one note at a time is read into one reused buffer (only the
    /// snippet is kept), and a search reads at most `max_search_bytes`.
    pub fn search(self: *Notes, arena: Allocator, query: []const u8, limit: usize) ![]Hit {
        var hits: std.ArrayList(Hit) = .empty;
        const q = std.mem.trim(u8, query, " \t\r\n");
        if (q.len == 0 or limit == 0) return hits.toOwnedSlice(arena);
        const all = try self.list(arena);
        for (all) |note| {
            if (!note.editable) continue;
            if (hits.items.len >= limit) break;
            if (containsIgnoreCase(note.title, q)) try hits.append(arena, .{ .path = note.path, .title = note.title, .snippet = "" });
        }
        var biggest: usize = 0;
        for (all) |note| {
            if (searchable(note)) biggest = @max(biggest, @as(usize, @intCast(note.size)));
        }
        const scratch = try self.allocator.alloc(u8, biggest);
        defer self.allocator.free(scratch);
        var scanned: u64 = 0;
        for (all) |note| {
            if (!searchable(note)) continue;
            if (hits.items.len >= limit) break;
            if (containsIgnoreCase(note.title, q)) continue;
            if (scanned + note.size > max_search_bytes) break;
            scanned += note.size;
            const text = scratch[0..@intCast(note.size)];
            self.readInto(text, note.cid, note.author_id, false) catch continue;
            const at = std.ascii.indexOfIgnoreCase(text, q) orelse continue;
            try hits.append(arena, .{ .path = note.path, .title = note.title, .snippet = try windowAround(arena, text, at, q.len) });
        }
        return hits.toOwnedSlice(arena);
    }

    fn searchable(note: Note) bool {
        return note.editable and note.size > 0 and note.size <= max_searched_bytes;
    }

    // ---- Writing ----

    /// A new note in `notebook` ("" for the top). The name is made unique
    /// atomically: "Shopping list", then "Shopping list 2", ...
    pub fn create(self: *Notes, gpa: Allocator, notebook: []const u8, title: []const u8, text: []const u8) !Note {
        if (text.len > max_note_bytes) return error.FileTooLarge;
        const dir = try notebookDir(gpa, notebook);
        defer gpa.free(dir);
        const stem = try sanitizeTitle(gpa, title);
        defer gpa.free(stem);
        const path = try self.putNew(gpa, dir, stem, ".md", text);
        defer gpa.free(path);
        return self.get(gpa, path);
    }

    /// A note from text shared into the app, at the top level. The title is
    /// the subject, else the shared file's name without its extension, else
    /// the first line; the text is the text, else the link.
    pub fn createFromShare(self: *Notes, gpa: Allocator, share: Share) !Note {
        const text = if (share.text.len > 0) share.text else share.url;
        if (!std.unicode.utf8ValidateSlice(text)) return error.NotText;
        return self.create(gpa, "", shareTitle(share, text), text);
    }

    /// Replaces the text if the note is still the one the editor loaded
    /// (`base` is its CID); otherwise error.Changed and nothing is stored.
    /// Saving a legacy ".txt" note also gives it its title as name.
    pub fn save(self: *Notes, gpa: Allocator, path: []const u8, text: []const u8, base: [32]u8) !Note {
        try requireNote(path);
        if (text.len > max_note_bytes) return error.FileTooLarge;
        const saved = try self.folder.putBytes(path, text, base);
        // The text is stored: what follows is best effort, so a failed
        // rename doesn't make the editor retry a save that happened.
        if (isLegacyName(SwarmFolder.splitParent(path).name)) {
            if (self.migrateOne(gpa, path, saved.cid)) |maybe| {
                if (maybe) |moved| {
                    defer gpa.free(moved);
                    return self.get(gpa, moved);
                }
            } else |err| std.debug.print("notes: renaming a saved legacy note failed: {any}\n", .{err});
        }
        return self.get(gpa, path);
    }

    /// What a front end answers when `save` or `rename` returned
    /// error.Changed: the note as it is now.
    pub fn changedOutcome(self: *Notes, gpa: Allocator, path: []const u8) Outcome {
        const note = self.get(gpa, path) catch return .{ .changed = true, .note = null };
        return .{ .changed = true, .note = note };
    }

    /// Gives the note another title (another file name in the same
    /// notebook). error.PathAlreadyExists when a note has that name,
    /// error.Changed when the note changed since `base`.
    pub fn rename(self: *Notes, gpa: Allocator, path: []const u8, title: []const u8, base: [32]u8) !Note {
        try requireNote(path);
        const parent = SwarmFolder.splitParent(path);
        const stem = try sanitizeTitle(gpa, title);
        defer gpa.free(stem);
        const name = try std.fmt.allocPrint(gpa, "{s}.md", .{stem});
        defer gpa.free(name);
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent.dir, name });
        defer gpa.free(target);
        if (std.mem.eql(u8, target, path)) return self.get(gpa, path);
        try self.folder.moveIfUnchanged(path, target, base);
        self.followPinQuietly(path, target);
        return self.get(gpa, target);
    }

    /// Moves a note to a notebook ("" for the top; a name nobody uses yet
    /// makes the notebook). error.PathAlreadyExists when the notebook has a
    /// note of that name.
    pub fn moveTo(self: *Notes, gpa: Allocator, path: []const u8, notebook: []const u8) !Note {
        try requireNote(path);
        const info = self.folder.fileInfo(path) orelse return error.FileNotFound;
        const dir = try notebookDir(gpa, notebook);
        defer gpa.free(dir);
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, SwarmFolder.splitParent(path).name });
        defer gpa.free(target);
        if (std.mem.eql(u8, target, path)) return self.get(gpa, path);
        try self.folder.moveIfUnchanged(path, target, info.cid);
        self.followPinQuietly(path, target);
        return self.get(gpa, target);
    }

    /// Deletes a note. What it returns lets `restore` undo it.
    pub fn remove(self: *Notes, path: []const u8) !Removed {
        try requireNote(path);
        const info = self.folder.fileInfo(path) orelse return error.FileNotFound;
        const pinned = blk: {
            var arena_state = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_state.deinit();
            self.pins_mutex.lock();
            defer self.pins_mutex.unlock();
            break :blk pinIndex(try self.loadPins(arena_state.allocator()), path) != null;
        };
        try self.folder.remove(path);
        if (pinned) self.setPinned(path, false) catch |err| std.debug.print("notes: unpinning a deleted note failed: {any}\n", .{err});
        return .{ .path = path, .cid = info.cid, .size = info.size, .author_id = info.author, .pinned = pinned };
    }

    /// Undoes a delete: writes the note back (under another name if the
    /// path was taken meanwhile) and pins it again if it was pinned.
    pub fn restore(self: *Notes, gpa: Allocator, removed: Removed) !Note {
        try requireNote(removed.path);
        if (removed.size > max_note_bytes) return error.FileTooLarge;
        const text = try self.readContent(gpa, removed.cid, removed.size, removed.author_id, true);
        defer gpa.free(text);
        const parent = SwarmFolder.splitParent(removed.path);
        const ext = std.fs.path.extension(parent.name);
        const stem = parent.name[0 .. parent.name.len - ext.len];
        const path = try self.putNew(gpa, parent.dir, stem, ext, text);
        defer gpa.free(path);
        if (removed.pinned) self.setPinned(path, true) catch |err| std.debug.print("notes: pinning a restored note failed: {any}\n", .{err});
        return self.get(gpa, path);
    }

    /// Pins or unpins on this device only (the swarm never sees it).
    pub fn setPinned(self: *Notes, path: []const u8, pinned: bool) !void {
        try requireNote(path);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        self.pins_mutex.lock();
        defer self.pins_mutex.unlock();
        var pins: std.ArrayList(Pin) = .empty;
        for (try self.loadPins(arena)) |p| {
            if (!std.mem.eql(u8, p.path, path)) try pins.append(arena, p);
        }
        if (pinned) {
            if (pins.items.len >= max_pins) return error.TooManyPins;
            const info = self.folder.fileInfo(path) orelse return error.FileNotFound;
            try pins.append(arena, .{ .path = path, .cid = info.cid });
        }
        try self.storePins(pins.items);
    }

    // ---- Conflicts ----

    /// Keeps `text` (what the editor holds) as a new note next to `path`,
    /// named as the folder names a conflict copy ("Ideas (conflict from
    /// Desk).md"), so the list shows it under its note.
    pub fn keepBoth(self: *Notes, gpa: Allocator, path: []const u8, text: []const u8) !Note {
        try requireNote(path);
        if (text.len > max_note_bytes) return error.FileTooLarge;
        const parent = SwarmFolder.splitParent(path);
        const ext = std.fs.path.extension(parent.name);
        const base_stem = parent.name[0 .. parent.name.len - ext.len];
        // "Plan (conflict from Desk).md", then "... from Desk 2).md": the
        // number stays inside the brackets so every copy is still read as
        // one (`conflictOf`).
        var n: usize = 1;
        while (n < 1000) : (n += 1) {
            const who = if (n == 1)
                try gpa.dupe(u8, self.folder.self_name)
            else
                try std.fmt.allocPrint(gpa, "{s} {d}", .{ self.folder.self_name, n });
            defer gpa.free(who);
            const stem = try manifest_mod.conflictStem(gpa, base_stem, who);
            defer gpa.free(stem);
            const copy_path = try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ parent.dir, stem, ext });
            defer gpa.free(copy_path);
            _ = self.folder.putBytes(copy_path, text, null) catch |err| switch (err) {
                error.Changed => continue, // taken
                else => return err,
            };
            return self.get(gpa, copy_path);
        }
        return error.TooManyNames;
    }

    /// Settles a conflict copy. `base` and `copy` carry the content the user
    /// saw; if either has changed since, error.Changed and nothing is stored.
    ///   use_copy: the copy's text replaces the note's;
    ///   append: the copy's text goes after the note's;
    ///   discard: the copy is deleted, the note left alone.
    /// The first two then delete the copy. error.NotAConflictCopy when
    /// `copy` is not a conflict copy of `base`.
    pub fn resolveCopy(self: *Notes, gpa: Allocator, copy: Ref, base: Ref, how: Resolution) !Resolved {
        try requireNote(copy.path);
        try requireNote(base.path);
        if (!isCopyOf(copy.path, base.path)) return error.NotAConflictCopy;
        const copy_info = self.folder.fileInfo(copy.path) orelse return error.FileNotFound;
        if (!std.mem.eql(u8, &copy_info.cid, &copy.cid)) return error.Changed;
        if (how == .discard) {
            const removed = try self.remove(copy.path);
            return .{ .outcome = .{ .changed = false, .note = self.get(gpa, base.path) catch null }, .removed = removed };
        }

        const base_info = self.folder.fileInfo(base.path) orelse return error.Changed;
        if (!std.mem.eql(u8, &base_info.cid, &base.cid)) return error.Changed;
        const copy_text = try self.readContent(gpa, copy_info.cid, copy_info.size, copy_info.author, true);
        defer gpa.free(copy_text);
        if (!std.unicode.utf8ValidateSlice(copy_text)) return error.NotText;
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        if (how == .append) {
            const base_text = try self.readContent(gpa, base_info.cid, base_info.size, base_info.author, true);
            defer gpa.free(base_text);
            try appendCopy(gpa, &joined, base_text, copy_text);
        } else {
            try joined.appendSlice(gpa, copy_text);
        }
        // The one compare-and-set: it fails if the note changed meanwhile.
        const saved = try self.save(gpa, base.path, joined.items, base.cid);
        const removed: ?Removed = self.remove(copy.path) catch |err| blk: {
            std.debug.print("notes: the merged copy could not be deleted: {any}\n", .{err});
            break :blk null;
        };
        return .{ .outcome = .{ .changed = false, .note = saved }, .removed = removed };
    }

    // ---- Legacy names ----

    /// Renames the notes this device wrote under their legacy names
    /// ("2026-10-28 17-49-03 Shopping list.txt" becomes "Shopping list.md"),
    /// keeping their modified time. Notes other devices wrote are left to
    /// them, so devices don't race on the same renames; a note edited since
    /// is tried again next time. Returns how many were renamed.
    pub fn migrateLegacy(self: *Notes, gpa: Allocator) !usize {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const all = try self.list(arena_state.allocator());
        var moved: usize = 0;
        for (all) |note| {
            if (!note.legacy or note.conflict_of != null) continue;
            if (!std.mem.eql(u8, &note.author_id, &self.folder.self_id.bytes)) continue;
            if (try self.migrateOne(gpa, note.path, note.cid)) |target| {
                gpa.free(target);
                moved += 1;
            }
        }
        return moved;
    }

    /// The after-sync pass: `migrateLegacy`, unless nothing under Notes/
    /// changed since the last one that ran to the end (then there is nothing
    /// new to rename, and listing every round would be waste).
    pub fn migrateIfNeeded(self: *Notes) void {
        const digest = self.folder.digestUnder(prefix);
        if (self.migrated_digest) |done| if (std.mem.eql(u8, &done, &digest)) return;
        const moved = self.migrateLegacy(self.allocator) catch |err| {
            std.debug.print("notes: renaming legacy notes failed (tried again next round): {any}\n", .{err});
            return;
        };
        if (moved > 0) std.debug.print("notes: renamed {d} legacy note(s)\n", .{moved});
        self.migrated_digest = self.folder.digestUnder(prefix);
    }

    // ---- Internals ----

    /// Renames one legacy note to its title as ".md". Null when the note
    /// changed meanwhile.
    fn migrateOne(self: *Notes, gpa: Allocator, path: []const u8, cid: [32]u8) !?[]u8 {
        const parent = SwarmFolder.splitParent(path);
        const ext = std.fs.path.extension(parent.name);
        const stem = try sanitizeTitle(gpa, legacyTitle(parent.name[0 .. parent.name.len - ext.len]));
        defer gpa.free(stem);
        var n: usize = 1;
        while (n < 10_000) : (n += 1) {
            const name = try numberedName(gpa, stem, n, ".md");
            defer gpa.free(name);
            const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent.dir, name });
            errdefer gpa.free(target);
            self.folder.moveIfUnchanged(path, target, cid) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    gpa.free(target);
                    continue;
                },
                error.Changed, error.FileNotFound => {
                    gpa.free(target);
                    return null;
                },
                else => return err,
            };
            self.followPinQuietly(path, target);
            return target;
        }
        return error.TooManyNames;
    }

    /// Writes a new file `<dir>/<stem>[ n]<ext>`, the first n whose name is
    /// free. The path is allocated in `gpa`. A taken name is refused before
    /// any block is built (`putBytes` checks first), so trying many names
    /// doesn't hash the text each time.
    fn putNew(self: *Notes, gpa: Allocator, dir: []const u8, stem: []const u8, ext: []const u8, text: []const u8) ![]u8 {
        var n: usize = 1;
        while (n < 10_000) : (n += 1) {
            const name = try numberedName(gpa, stem, n, ext);
            defer gpa.free(name);
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
            errdefer gpa.free(path);
            _ = self.folder.putBytes(path, text, null) catch |err| switch (err) {
                error.Changed => {
                    gpa.free(path);
                    continue; // taken: a note by that name exists
                },
                else => return err,
            };
            return path;
        }
        return error.TooManyNames;
    }

    /// Fills `dest` with the file's bytes. `fetch`: ask other devices for
    /// blocks this one lacks; else only this device's store
    /// (error.BlockNotFound).
    fn readInto(self: *Notes, dest: []u8, cid: [32]u8, author: [32]u8, fetch: bool) !void {
        var offset: usize = 0;
        while (offset < dest.len) {
            const chunk = dest[offset..];
            const n = self.folder.readLocal(self.allocator, cid, offset, chunk) catch |err| blk: {
                if (!fetch or err != error.BlockNotFound) return err;
                break :blk try self.folder.readAt(self.allocator, cid, author, offset, chunk);
            };
            if (n == 0) return error.UnexpectedEof;
            offset += n;
        }
    }

    /// The file's bytes, allocated in `gpa`.
    fn readContent(self: *Notes, gpa: Allocator, cid: [32]u8, size: u64, author: [32]u8, fetch: bool) ![]u8 {
        if (size > max_note_bytes) return error.FileTooLarge;
        const text = try gpa.alloc(u8, @intCast(size));
        errdefer gpa.free(text);
        try self.readInto(text, cid, author, fetch);
        return text;
    }

    // ---- Pins ----

    const Pin = struct { path: []const u8, cid: [32]u8 };

    /// The pins file; a missing file is no pins. A file that is too large to
    /// be ours is moved aside like other corrupt state. Caller holds
    /// `pins_mutex`.
    fn loadPins(self: *Notes, arena: Allocator) ![]Pin {
        const io = self.folder.io;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.pins_path, arena, .limited(max_pins_file)) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            error.StreamTooLong => {
                self.movePinsAside();
                return &.{};
            },
            else => return err,
        };
        var pins: std.ArrayList(Pin) = .empty;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
            if (tab == 0 or line.len - tab - 1 != 64) continue;
            var cid: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&cid, line[tab + 1 ..]) catch continue;
            if (pins.items.len >= max_pins) break;
            try pins.append(arena, .{ .path = line[0..tab], .cid = cid });
        }
        return pins.items;
    }

    fn movePinsAside(self: *Notes) void {
        const io = self.folder.io;
        const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
        const aside = std.fmt.allocPrint(self.allocator, "{s}.corrupt-{d}", .{ self.pins_path, seconds }) catch return;
        defer self.allocator.free(aside);
        std.Io.Dir.cwd().rename(self.pins_path, std.Io.Dir.cwd(), aside, io) catch {};
        std.debug.print("notes: the pins file is not valid; moved to {s}\n", .{aside});
    }

    /// Writes the pins file whole: a temporary file, then a rename. Caller
    /// holds `pins_mutex`.
    fn storePins(self: *Notes, pins: []const Pin) !void {
        const io = self.folder.io;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        for (pins) |p| {
            try out.appendSlice(self.allocator, p.path);
            try out.append(self.allocator, '\t');
            try out.appendSlice(self.allocator, &std.fmt.bytesToHex(p.cid, .lower));
            try out.append(self.allocator, '\n');
        }
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.pins_path});
        defer self.allocator.free(tmp);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = out.items });
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.pins_path, io);
    }

    const Reconciled = struct { pins: []Pin, changed: bool };

    /// Pins whose note was moved follow it; pins whose note was deleted go.
    /// A deleted path is checked first: only a note that really was moved
    /// from it (the folder's `movedFrom`, with the pin's last content or file
    /// name) takes the pin over, never a note that merely looks alike. A
    /// pin's CID is refreshed when the note was edited.
    fn reconcilePins(self: *Notes, arena: Allocator, pins: []Pin, notes: []const Note, index: *const std.StringHashMapUnmanaged(usize)) !Reconciled {
        var out: std.ArrayList(Pin) = .empty;
        var changed = false;
        for (pins) |pin| {
            var next = pin;
            if (findNote(notes, index, pin.path)) |n| {
                if (!std.mem.eql(u8, &n.cid, &pin.cid)) {
                    next.cid = n.cid;
                    changed = true;
                }
            } else if (self.folder.isGone(pin.path)) {
                changed = true;
                const target = try self.movedPinTarget(arena, pin, notes, index) orelse continue;
                next = .{ .path = target.path, .cid = target.cid };
            }
            if (pinIndex(out.items, next.path) != null) {
                changed = true;
                continue;
            }
            try out.append(arena, next);
        }
        return .{ .pins = out.items, .changed = changed };
    }

    /// The note a deleted pin's note was moved to, if it was moved.
    fn movedPinTarget(self: *Notes, arena: Allocator, pin: Pin, notes: []const Note, index: *const std.StringHashMapUnmanaged(usize)) !?Note {
        const name = SwarmFolder.splitParent(pin.path).name;
        for (try self.folder.movedFrom(arena, pin.path)) |path| {
            const n = findNote(notes, index, path) orelse continue;
            if (std.mem.eql(u8, &n.cid, &pin.cid) or std.mem.eql(u8, SwarmFolder.splitParent(n.path).name, name)) return n;
        }
        return null;
    }

    /// A local rename or move: the pin goes to the new path.
    fn followPin(self: *Notes, old_path: []const u8, new_path: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        self.pins_mutex.lock();
        defer self.pins_mutex.unlock();
        const pins = try self.loadPins(arena);
        const at = pinIndex(pins, old_path) orelse return;
        pins[at].path = new_path;
        try self.storePins(pins);
    }

    /// The move is stored: a pin that can't follow it (file I/O) is only
    /// logged, and the list fixes it from the folder's records next time.
    fn followPinQuietly(self: *Notes, old_path: []const u8, new_path: []const u8) void {
        self.followPin(old_path, new_path) catch |err| std.debug.print("notes: moving a pin failed: {any}\n", .{err});
    }
};

// ---- Names ----

/// The rule for what is a note: a valid swarm path under `Notes/`. Every
/// public method that takes a path starts with it, so a front end can't
/// reach other files of the swarm folder through the notes service.
fn requireNote(path: []const u8) error{NotANote}!void {
    if (!std.mem.startsWith(u8, path, prefix) or !manifest_mod.validPath(path)) return error.NotANote;
}

/// A title as a file name stem: control characters, '/' and '\' become
/// a space (a run of them one space), the ends are trimmed of spaces and dots, and it is cut at
/// 120 bytes on a character boundary. Empty becomes "Untitled". Caller frees.
pub fn sanitizeTitle(allocator: Allocator, title: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, title, " \t\r\n.");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var view = std.unicode.Utf8View.init(trimmed) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepointSlice()) |codepoint| {
        if (out.items.len + codepoint.len > max_title_bytes) break;
        const c = codepoint[0];
        if (codepoint.len == 1 and (c < 0x20 or c == 0x7f or c == '/' or c == '\\' or c == ' ')) {
            // A run of spaces and replaced characters is one space: "a / b" is "a b".
            if (out.items.len == 0 or out.items[out.items.len - 1] != ' ') try out.append(allocator, ' ');
        } else {
            try out.appendSlice(allocator, codepoint);
        }
    }
    const safe = std.mem.trim(u8, out.items, " .");
    return allocator.dupe(u8, if (safe.len == 0) "Untitled" else safe);
}

/// "Untitled" for an empty title; else the title as a ".md" file name.
pub fn titleToName(allocator: Allocator, title: []const u8) ![]u8 {
    const stem = try sanitizeTitle(allocator, title);
    defer allocator.free(stem);
    return std.fmt.allocPrint(allocator, "{s}.md", .{stem});
}

/// The title of a note made from shared text: the subject; else the shared
/// file's name without ".md", ".markdown" or ".txt"; else the first
/// non-blank line of `body`. Not yet cleaned (see `sanitizeTitle`).
fn shareTitle(share: Notes.Share, body: []const u8) []const u8 {
    const subject = std.mem.trim(u8, share.subject, " \t\r\n");
    if (subject.len > 0) return subject;
    var name = std.mem.trim(u8, share.name, " \t\r\n");
    for ([_][]const u8{ ".markdown", ".md", ".txt" }) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) {
            name = name[0 .. name.len - ext.len];
            break;
        }
    }
    if (std.mem.trim(u8, name, " \t\r\n").len > 0) return name;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) return t;
    }
    return "";
}

/// `stem.ext` for n = 1, `stem n.ext` after: the names tried for a title
/// that is taken.
fn numberedName(allocator: Allocator, stem: []const u8, n: usize, ext: []const u8) ![]u8 {
    if (n <= 1) return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
    return std.fmt.allocPrint(allocator, "{s} {d}{s}", .{ stem, n, ext });
}

/// "Notes" or "Notes/Work/Ideas" for a notebook name ("" or "Work/Ideas").
/// Every part is sanitised like a title; empty parts are skipped. Caller frees.
fn notebookDir(allocator: Allocator, notebook: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, Notes.root);
    var depth: usize = 0;
    var parts = std.mem.splitScalar(u8, notebook, '/');
    while (parts.next()) |part| {
        if (std.mem.trim(u8, part, " \t\r\n.").len == 0) continue;
        depth += 1;
        if (depth > 3) return error.NotebookTooDeep;
        const name = try sanitizeTitle(allocator, part);
        defer allocator.free(name);
        try out.append(allocator, '/');
        try out.appendSlice(allocator, name);
    }
    if (!manifest_mod.validPath(out.items)) return error.InvalidPath;
    return out.toOwnedSlice(allocator);
}

/// A legacy name's title: "2026-10-28 17-49-03 Shopping list" gives
/// "Shopping list". Anything else is returned as it is.
pub fn legacyTitle(stem: []const u8) []const u8 {
    if (stem.len <= 20) return stem;
    const shape = "dddd-dd-dd dd-dd-dd ";
    for (shape, stem[0..20]) |s, c| {
        if (s == 'd' and !std.ascii.isDigit(c)) return stem;
        if (s != 'd' and s != c) return stem;
    }
    return stem[20..];
}

fn isLegacyName(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    return std.mem.eql(u8, ext, ".txt") and legacyTitle(name[0 .. name.len - ext.len]).len != name.len - ext.len;
}

fn noteOf(item: SwarmFolder.Item) Notes.Note {
    const ext = std.fs.path.extension(item.name);
    const editable = std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".txt");
    const stem = item.name[0 .. item.name.len - (if (editable) ext.len else 0)];
    const legacy = isLegacyName(item.name);
    const parent = SwarmFolder.splitParent(item.path).dir;
    return .{
        .path = item.path,
        .title = if (legacy) legacyTitle(stem) else stem,
        .notebook = if (parent.len <= Notes.root.len) "" else parent[Notes.root.len + 1 ..],
        .cid = item.cid orelse [_]u8{0} ** 32,
        .size = item.size,
        .mtime = item.mtime,
        .author = item.author,
        .author_id = item.author_id orelse [_]u8{0} ** 32,
        .legacy = legacy,
        .editable = editable,
    };
}

/// Where the note a conflict copy was made from would be: the copy's name
/// without the marker, in the same folder. Written into `buf`.
fn conflictBasePath(buf: []u8, copy: Notes.Note) ?[]const u8 {
    if (!copy.editable) return null;
    const parent = SwarmFolder.splitParent(copy.path);
    const base = manifest_mod.conflictOf(parent.name) orelse return null;
    const ext = std.fs.path.extension(parent.name);
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ parent.dir, base, ext }) catch null;
}

/// The path of the note a conflict copy was made from, if the listing has it.
fn conflictBase(notes: []const Notes.Note, index: *const std.StringHashMapUnmanaged(usize), copy: Notes.Note) ?[]const u8 {
    var buf: [manifest_mod.max_path_len]u8 = undefined;
    const path = conflictBasePath(&buf, copy) orelse return null;
    const at = index.get(path) orelse return null;
    return if (notes[at].editable) notes[at].path else null;
}

/// Whether `copy` is named as a conflict copy of the note at `base`.
fn isCopyOf(copy: []const u8, base: []const u8) bool {
    const c = SwarmFolder.splitParent(copy);
    const b = SwarmFolder.splitParent(base);
    if (!std.mem.eql(u8, c.dir, b.dir)) return false;
    const stem = manifest_mod.conflictOf(c.name) orelse return false;
    const ext = std.fs.path.extension(c.name);
    return b.name.len == stem.len + ext.len and std.mem.startsWith(u8, b.name, stem) and std.mem.endsWith(u8, b.name, ext);
}

/// `base`, a blank line, then `copy`; just `copy` for an empty note.
fn appendCopy(gpa: Allocator, out: *std.ArrayList(u8), base: []const u8, copy: []const u8) !void {
    const head = std.mem.trimEnd(u8, base, " \t\r\n");
    if (head.len == 0) return out.appendSlice(gpa, copy);
    try out.appendSlice(gpa, head);
    try out.appendSlice(gpa, "\n\n");
    try out.appendSlice(gpa, std.mem.trimStart(u8, copy, " \t\r\n"));
}

/// The distinct notebooks of the notes the editor opens, sorted.
pub fn notebooksOf(arena: Allocator, notes: []const Notes.Note) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (notes) |n| {
        if (!n.editable or n.notebook.len == 0) continue;
        var seen = false;
        for (names.items) |name| seen = seen or std.mem.eql(u8, name, n.notebook);
        if (!seen) try names.append(arena, n.notebook);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}

fn newerFirst(_: void, a: Notes.Note, b: Notes.Note) bool {
    if (a.pinned != b.pinned) return a.pinned;
    if (a.mtime != b.mtime) return a.mtime > b.mtime;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn findNote(notes: []const Notes.Note, index: *const std.StringHashMapUnmanaged(usize), path: []const u8) ?Notes.Note {
    const at = index.get(path) orelse return null;
    return if (notes[at].editable) notes[at] else null;
}

fn pinIndex(pins: anytype, path: []const u8) ?usize {
    for (pins, 0..) |p, i| if (std.mem.eql(u8, p.path, path)) return i;
    return null;
}

// ---- Text helpers ----

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// `bytes` cut back to whole characters (a read may stop mid-character); an
/// empty slice when it isn't UTF-8 at all.
fn validPrefix(bytes: []const u8) []const u8 {
    var end = bytes.len;
    var tries: usize = 0;
    while (tries < 4 and !std.unicode.utf8ValidateSlice(bytes[0..end])) : (tries += 1) {
        if (end == 0) break;
        end -= 1;
    }
    return if (std.unicode.utf8ValidateSlice(bytes[0..end])) bytes[0..end] else "";
}

/// The first non-blank lines joined by spaces, cut at `max` bytes on a
/// character boundary.
fn previewOf(arena: Allocator, text: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, line);
        if (out.items.len >= max) break;
    }
    return arena.dupe(u8, validPrefix(out.items[0..@min(out.items.len, max)]));
}

/// About 60 bytes of text either side of a match, on character boundaries.
fn windowAround(arena: Allocator, text: []const u8, at: usize, len: usize) ![]const u8 {
    var start = at -| 60;
    var end = @min(text.len, at + len + 60);
    while (start < at and start < text.len and (text[start] & 0xC0) == 0x80) start += 1;
    while (end > at + len and end < text.len and (text[end] & 0xC0) == 0x80) end -= 1;
    var flat: std.ArrayList(u8) = .empty;
    for (text[start..end]) |c| try flat.append(arena, if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
    return arena.dupe(u8, validPrefix(flat.items));
}

// ---- Tests ----

const SharedFixture = @import("test_fixture.zig").Fixture(SwarmFolder);

const Fixture = struct {
    base: SharedFixture,
    folder: *SwarmFolder,
    dir: []const u8,
    notes: Notes,
    arena_state: std.heap.ArenaAllocator,

    /// `device_byte`: this device's ID, filled with that byte.
    fn open(self: *Fixture, device_byte: u8, name: []const u8) !void {
        const allocator = std.testing.allocator;
        try self.base.open(device_byte, name);
        errdefer self.base.close();
        self.folder = self.base.folder;
        self.dir = self.base.dir;
        const pins = try std.fs.path.join(allocator, &.{ self.dir, "notes-pinned" });
        defer allocator.free(pins);
        self.notes = try Notes.init(allocator, self.folder, pins);
        self.arena_state = std.heap.ArenaAllocator.init(allocator);
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    /// Another service over the same swarm folder with its own pins, as a
    /// second device profile would have.
    fn otherProfile(self: *Fixture) !Notes {
        const other = try std.fs.path.join(std.testing.allocator, &.{ self.dir, "other" });
        defer std.testing.allocator.free(other);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, other);
        const pins = try std.fs.path.join(std.testing.allocator, &.{ other, "notes-pinned" });
        defer std.testing.allocator.free(pins);
        return Notes.init(std.testing.allocator, self.folder, pins);
    }

    fn close(self: *Fixture) void {
        self.arena_state.deinit();
        self.notes.deinit();
        self.base.close();
    }
};

fn titles(arena: Allocator, notes: []const Notes.Note) ![]const []const u8 {
    const out = try arena.alloc([]const u8, notes.len);
    for (notes, out) |n, *o| o.* = n.title;
    return out;
}

test "notes: titles become safe file names" {
    const a = std.testing.allocator;
    const name = try titleToName(a, "  a/b\\c  ");
    defer a.free(name);
    try std.testing.expectEqualStrings("a b c.md", name);
    const dots = try titleToName(a, " ..hidden.. ");
    defer a.free(dots);
    try std.testing.expectEqualStrings("hidden.md", dots);
    const empty = try titleToName(a, " \n\t");
    defer a.free(empty);
    try std.testing.expectEqualStrings("Untitled.md", empty);
    const control = try titleToName(a, "tab\there\x01");
    defer a.free(control);
    try std.testing.expectEqualStrings("tab here.md", control);
    try std.testing.expectError(error.InvalidUtf8, titleToName(a, "\xff"));
    // 120 bytes at most, never cutting a character.
    const long = try titleToName(a, "ñ" ** 70);
    defer a.free(long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long));
    try std.testing.expectEqual(@as(usize, 120 + 3), long.len);
    const ascii = try titleToName(a, "x" ** 300);
    defer a.free(ascii);
    try std.testing.expectEqual(@as(usize, 120 + 3), ascii.len);
}

test "notes: notebook names become folders" {
    const a = std.testing.allocator;
    const top = try notebookDir(a, "");
    defer a.free(top);
    try std.testing.expectEqualStrings("Notes", top);
    const nested = try notebookDir(a, " Work //Ideas/ ../ ");
    defer a.free(nested);
    try std.testing.expectEqualStrings("Notes/Work/Ideas", nested);
    try std.testing.expectError(error.NotebookTooDeep, notebookDir(a, "a/b/c/d"));
}

test "notes: legacy titles are recognised" {
    try std.testing.expectEqualStrings("Shopping list", legacyTitle("2026-10-28 17-49-03 Shopping list"));
    try std.testing.expectEqualStrings("2026-10-28 Shopping", legacyTitle("2026-10-28 Shopping"));
    try std.testing.expectEqualStrings("2026-1x-28 17-49-03 Shopping list", legacyTitle("2026-1x-28 17-49-03 Shopping list"));
    try std.testing.expectEqualStrings("2026-10-28 17-49-03", legacyTitle("2026-10-28 17-49-03"));
}

test "notes: create picks unique names and keeps notebooks" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const first = try f.notes.create(a, "", "Shopping list", "milk");
    const second = try f.notes.create(a, "", "Shopping list", "eggs");
    const third = try f.notes.create(a, "", "Shopping list", "bread");
    try std.testing.expectEqualStrings("Notes/Shopping list.md", first.path);
    try std.testing.expectEqualStrings("Notes/Shopping list 2.md", second.path);
    try std.testing.expectEqualStrings("Notes/Shopping list 3.md", third.path);
    try std.testing.expectEqualStrings("Shopping list 2", second.title);
    const empty_title = try f.notes.create(a, "", "  ", "");
    try std.testing.expectEqualStrings("Untitled", empty_title.title);
    try std.testing.expectEqual(@as(u64, 0), empty_title.size);

    const work = try f.notes.create(a, "Work", "Standup", "notes");
    try std.testing.expectEqualStrings("Notes/Work/Standup.md", work.path);
    try std.testing.expectEqualStrings("Work", work.notebook);
    try std.testing.expectEqualStrings("Desk", work.author);
    try std.testing.expectEqualSlices(u8, &f.folder.self_id.bytes, &work.author_id);
    const books = try f.notes.notebooks(a);
    try std.testing.expectEqual(@as(usize, 1), books.len);
    try std.testing.expectEqualStrings("Work", books[0]);

    const read = try f.notes.read(a, first.path);
    try std.testing.expectEqualStrings("milk", read.text);
    try std.testing.expectEqualSlices(u8, &first.cid, &read.cid);
    try std.testing.expectError(error.FileNotFound, f.notes.read(a, "Notes/none.md"));
    const big = try std.testing.allocator.alloc(u8, max_note_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try std.testing.expectError(error.FileTooLarge, f.notes.create(a, "", "Big", big));
}

test "notes: save compares the content the editor loaded" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Plan", "v1");
    const saved = try f.notes.save(a, note.path, "v2", note.cid);
    try std.testing.expect(!std.mem.eql(u8, &note.cid, &saved.cid));
    try std.testing.expectEqual(@as(u64, 2), saved.size);
    // Another device's edit arrived while this editor still had v1.
    try std.testing.expectError(error.Changed, f.notes.save(a, note.path, "stale", note.cid));
    try std.testing.expectEqualStrings("v2", (try f.notes.read(a, note.path)).text);
    // Overwriting on purpose: the editor passes the CID it just saw.
    const forced = try f.notes.save(a, note.path, "mine", saved.cid);
    try std.testing.expectEqualStrings("mine", (try f.notes.read(a, forced.path)).text);
    try std.testing.expectError(error.Changed, f.notes.save(a, "Notes/none.md", "x", saved.cid));
}

test "notes: rename keeps the content, refuses a taken title and a stale base" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const one = try f.notes.create(a, "Work", "One", "1");
    const two = try f.notes.create(a, "Work", "Two", "2");
    const renamed = try f.notes.rename(a, one.path, "Uno / primero", one.cid);
    try std.testing.expectEqualStrings("Notes/Work/Uno primero.md", renamed.path);
    try std.testing.expectEqualSlices(u8, &one.cid, &renamed.cid);
    try std.testing.expectEqual(one.mtime, renamed.mtime);
    try std.testing.expect(f.folder.fileInfo(one.path) == null);
    try std.testing.expectError(error.PathAlreadyExists, f.notes.rename(a, two.path, "Uno primero", two.cid));
    try std.testing.expectError(error.Changed, f.notes.rename(a, two.path, "Dos", one.cid));
    // The same title is no change.
    const same = try f.notes.rename(a, two.path, "Two", two.cid);
    try std.testing.expectEqualStrings(two.path, same.path);
    // Another notebook.
    const moved = try f.notes.moveTo(a, two.path, "Home");
    try std.testing.expectEqualStrings("Notes/Home/Two.md", moved.path);
    try std.testing.expectEqualStrings("Home", moved.notebook);
    const back = try f.notes.moveTo(a, moved.path, "");
    try std.testing.expectEqualStrings("Notes/Two.md", back.path);
    _ = try f.notes.create(a, "", "Uno primero", "again");
    try std.testing.expectError(error.PathAlreadyExists, f.notes.moveTo(a, renamed.path, ""));
    // A notebook with nothing in it is gone.
    const books = try f.notes.notebooks(a);
    try std.testing.expectEqual(@as(usize, 1), books.len);
    try std.testing.expectEqualStrings("Work", books[0]);
}

test "notes: delete and restore" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "Work", "Keep me", "precious");
    try f.notes.setPinned(note.path, true);
    const removed = try f.notes.remove(note.path);
    try std.testing.expect(removed.pinned);
    try std.testing.expect(f.folder.fileInfo(note.path) == null);
    try std.testing.expectEqual(@as(usize, 0), (try f.notes.list(a)).len);
    try std.testing.expectError(error.FileNotFound, f.notes.remove(note.path));

    const back = try f.notes.restore(a, removed);
    try std.testing.expectEqualStrings(note.path, back.path);
    try std.testing.expectEqualStrings("precious", (try f.notes.read(a, back.path)).text);
    try std.testing.expect(back.pinned);

    // The name was taken meanwhile: the restored note gets another one.
    const gone = try f.notes.remove(back.path);
    _ = try f.notes.create(a, "Work", "Keep me", "new");
    const second = try f.notes.restore(a, gone);
    try std.testing.expectEqualStrings("Notes/Work/Keep me 2.md", second.path);
}

test "notes: pins are set, unset and survive a restart" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Pinned", "x");
    try std.testing.expect(!(try f.notes.get(a, note.path)).pinned);
    try f.notes.setPinned(note.path, true);
    try f.notes.setPinned(note.path, true); // twice is one pin
    try std.testing.expect((try f.notes.get(a, note.path)).pinned);
    try std.testing.expect((try f.notes.list(a))[0].pinned);

    // A new service over the same data directory: the restarted app.
    var restarted = try Notes.init(std.testing.allocator, f.folder, f.notes.pins_path);
    defer restarted.deinit();
    try std.testing.expect((try restarted.list(a))[0].pinned);

    try f.notes.setPinned(note.path, false);
    try std.testing.expect(!(try restarted.list(a))[0].pinned);
    try std.testing.expectError(error.FileNotFound, f.notes.setPinned("Notes/none.md", true));
}

test "notes: a pin follows a rename on this device and one made elsewhere" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Alpha", "text");
    try f.notes.setPinned(note.path, true);
    const renamed = try f.notes.rename(a, note.path, "Beta", note.cid);
    try std.testing.expect(renamed.pinned);

    // Another device renamed it (here: a move through the folder, which is
    // what arrives from a peer): the pin is found again by content.
    try f.folder.move(renamed.path, "Notes/Gamma.md", .{});
    const listing = try f.notes.list(a);
    try std.testing.expectEqual(@as(usize, 1), listing.len);
    try std.testing.expectEqualStrings("Gamma", listing[0].title);
    try std.testing.expect(listing[0].pinned);

    // After an edit elsewhere and a move to another notebook, the file name
    // finds it.
    const gamma = f.folder.fileInfo("Notes/Gamma.md").?;
    _ = try f.folder.putBytes("Notes/Gamma.md", "edited", gamma.cid);
    try std.testing.expect((try f.notes.list(a))[0].pinned); // pin refreshed to the new content
    _ = try f.folder.putBytes("Notes/Gamma.md", "edited again", f.folder.fileInfo("Notes/Gamma.md").?.cid);
    try f.folder.move("Notes/Gamma.md", "Notes/Work/Gamma.md", .{});
    const after = try f.notes.list(a);
    try std.testing.expectEqualStrings("Work", after[0].notebook);
    try std.testing.expect(after[0].pinned);
}

test "notes: a pin is dropped when its note is deleted" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Short lived", "x");
    try f.notes.setPinned(note.path, true);
    // Deleted on another device: the tombstone arrives through the manifest.
    try f.folder.remove(note.path);
    try std.testing.expectEqual(@as(usize, 0), (try f.notes.list(a)).len);
    // A note written back at the same path is not pinned again.
    const again = try f.notes.create(a, "", "Short lived", "y");
    try std.testing.expect(!again.pinned);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, f.notes.pins_path, a, .limited(4096));
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "notes: a pin on a path the folder has never heard of waits for the first sync" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    // The pins file outlived the manifest (reinstalled, not yet pulled).
    try f.notes.storePins(&.{.{ .path = "Notes/Ghost.md", .cid = [_]u8{7} ** 32 }});
    _ = try f.notes.list(a);
    try std.testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFileAlloc(std.testing.io, f.notes.pins_path, a, .limited(4096)), "Ghost") != null);
    // Once a round has run and the swarm still has no such note, it goes.
    f.folder.last_sync = 5;
    _ = try f.notes.list(a);
    try std.testing.expectEqual(@as(usize, 0), (try std.Io.Dir.cwd().readFileAlloc(std.testing.io, f.notes.pins_path, a, .limited(4096))).len);
}

test "notes: pins are this device's only" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Mine", "x");
    try f.notes.setPinned(note.path, true);
    // Nothing about the pin is in the swarm folder.
    for (f.folder.manifest.entries.values()) |e| try std.testing.expect(std.mem.startsWith(u8, e.path, "Notes/"));
    try std.testing.expectEqual(@as(usize, 1), f.folder.status().entries);
    // Another device has its own data directory and sees no pin.
    var phone = try f.otherProfile();
    defer phone.deinit();
    try std.testing.expect(!(try phone.list(a))[0].pinned);
    try std.testing.expect((try f.notes.list(a))[0].pinned);
}

test "notes: the list is pinned first, then newest first" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const old = try f.notes.create(a, "", "Old", "o");
    const mid = try f.notes.create(a, "Work", "Mid", "m");
    const new = try f.notes.create(a, "", "New", "n");
    const pinned_old = try f.notes.create(a, "", "Pinned old", "p");
    try f.folder.setMtime(old.path, 1_000);
    try f.folder.setMtime(mid.path, 2_000);
    try f.folder.setMtime(new.path, 3_000);
    try f.folder.setMtime(pinned_old.path, 500);
    try f.notes.setPinned(pinned_old.path, true);
    const order = try titles(a, try f.notes.list(a));
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqualStrings("Pinned old", order[0]);
    try std.testing.expectEqualStrings("New", order[1]);
    try std.testing.expectEqualStrings("Mid", order[2]);
    try std.testing.expectEqualStrings("Old", order[3]);
}

test "notes: legacy notes show their title and are renamed by the device that wrote them" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    _ = try f.folder.putBytes("Notes/2026-10-28 17-49-03 Shopping list.txt", "milk", null);
    try f.folder.setMtime("Notes/2026-10-28 17-49-03 Shopping list.txt", 1_793_000_000);
    _ = try f.folder.putBytes("Notes/2026-10-29 08-00-00 Plan.txt", "plan", null);
    _ = try f.folder.putBytes("Notes/Plan.md", "already a note", null);
    _ = try f.folder.putBytes("Notes/Dropped.txt", "a plain txt", null);
    _ = try f.folder.putBytes("Notes/picture.png", "png", null);

    const before = try f.notes.list(a);
    var legacy_count: usize = 0;
    for (before) |n| {
        if (n.legacy) legacy_count += 1;
        if (std.mem.eql(u8, n.path, "Notes/2026-10-28 17-49-03 Shopping list.txt")) {
            try std.testing.expectEqualStrings("Shopping list", n.title);
            try std.testing.expect(n.editable);
        }
        if (std.mem.eql(u8, n.path, "Notes/picture.png")) try std.testing.expect(!n.editable);
        if (std.mem.eql(u8, n.path, "Notes/Dropped.txt")) try std.testing.expect(!n.legacy);
    }
    try std.testing.expectEqual(@as(usize, 2), legacy_count);

    try std.testing.expectEqual(@as(usize, 2), try f.notes.migrateLegacy(a));
    const shopping = f.folder.fileInfo("Notes/Shopping list.md").?;
    try std.testing.expectEqual(@as(u64, 1_793_000_000), shopping.mtime); // modified time kept
    try std.testing.expect(f.folder.fileInfo("Notes/2026-10-28 17-49-03 Shopping list.txt") == null);
    // "Plan" was taken.
    try std.testing.expectEqualStrings("already a note", (try f.notes.read(a, "Notes/Plan.md")).text);
    try std.testing.expectEqualStrings("plan", (try f.notes.read(a, "Notes/Plan 2.md")).text);
    try std.testing.expect(f.folder.fileInfo("Notes/Dropped.txt") != null);
    try std.testing.expectEqual(@as(usize, 0), try f.notes.migrateLegacy(a));
}

test "notes: a legacy note written by another device is left to it, and saving renames it" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    var pixel: Fixture = undefined;
    try pixel.open(0x55, "Pixel");
    defer pixel.close();
    const a = desk.arena();

    const legacy = "Notes/2026-10-28 17-49-03 From phone.txt";
    _ = try pixel.folder.putBytes(legacy, "hello", null);
    try std.testing.expect(try desk.folder.manifest.merge(pixel.folder.manifest.get(legacy).?));
    const listing = try desk.notes.list(a);
    try std.testing.expectEqualStrings("From phone", listing[0].title);
    try std.testing.expectEqualStrings("Pixel", listing[0].author);
    // Not Desk's to rename.
    try std.testing.expectEqual(@as(usize, 0), try desk.notes.migrateLegacy(a));
    try std.testing.expect(desk.folder.fileInfo(legacy) != null);
    // Editing makes it Desk's, and the save gives it its title as name.
    const saved = try desk.notes.save(a, legacy, "hello again", listing[0].cid);
    try std.testing.expectEqualStrings("Notes/From phone.md", saved.path);
    try std.testing.expect(!saved.legacy);
    try std.testing.expect(desk.folder.fileInfo(legacy) == null);
    try std.testing.expectEqualStrings("hello again", (try desk.notes.read(a, saved.path)).text);
}

test "notes: a conflict copy points at its note" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    var pixel: Fixture = undefined;
    try pixel.open(0x55, "Pixel");
    defer pixel.close();
    const a = desk.arena();

    // Both devices wrote the same new note without having seen each other.
    _ = try desk.folder.putBytes("Notes/Ideas.md", "from the desk", null);
    _ = try pixel.folder.putBytes("Notes/Ideas.md", "from the phone", null);
    try std.testing.expect(try desk.folder.manifest.merge(pixel.folder.manifest.get("Notes/Ideas.md").?));

    const listing = try desk.notes.list(a);
    try std.testing.expectEqual(@as(usize, 2), listing.len);
    var copies: usize = 0;
    for (listing) |n| {
        if (n.conflict_of) |base| {
            copies += 1;
            try std.testing.expectEqualStrings("Notes/Ideas.md", base);
            try std.testing.expect(std.mem.startsWith(u8, n.title, "Ideas (conflict from "));
        } else try std.testing.expectEqualStrings("Ideas", n.title);
    }
    try std.testing.expectEqual(@as(usize, 1), copies);
}

test "notes: search finds titles, then the text of notes held here" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    var pixel: Fixture = undefined;
    try pixel.open(0x55, "Pixel");
    defer pixel.close();
    const a = desk.arena();

    _ = try desk.notes.create(a, "", "Wifi password", "network: Home\nkey: hunter2");
    _ = try desk.notes.create(a, "", "Trip", "Book the hotel in Lisbon,\nthen the flights.");
    _ = try desk.notes.create(a, "", "Lisbon", "see Trip");
    // A note this device lists but whose blocks live on the phone.
    _ = try pixel.folder.putBytes("Notes/Remote.md", "mentions LISBON too", null);
    try std.testing.expect(try desk.folder.manifest.merge(pixel.folder.manifest.get("Notes/Remote.md").?));

    const hits = try desk.notes.search(a, "lisbon", 10);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("Lisbon", hits[0].title); // title first
    try std.testing.expectEqualStrings("Trip", hits[1].title);
    try std.testing.expect(std.mem.indexOf(u8, hits[1].snippet, "Book the hotel in Lisbon") != null);
    try std.testing.expectEqual(@as(usize, 1), (try desk.notes.search(a, "lisbon", 1)).len);
    try std.testing.expectEqual(@as(usize, 1), (try desk.notes.search(a, "HUNTER2", 10)).len);
    try std.testing.expectEqual(@as(usize, 0), (try desk.notes.search(a, "   ", 10)).len);
    try std.testing.expectEqual(@as(usize, 0), (try desk.notes.search(a, "nothing like it", 10)).len);
}

test "notes: snippets come from local blocks only" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    var pixel: Fixture = undefined;
    try pixel.open(0x55, "Pixel");
    defer pixel.close();
    const a = desk.arena();

    const note = try desk.notes.create(a, "", "Todo", "\n\n  First line  \n\nSecond line\n" ++ "x" ** 400);
    const text = (try desk.notes.snippet(a, note)).?;
    try std.testing.expect(std.mem.startsWith(u8, text, "First line Second line xxx"));
    try std.testing.expect(text.len <= 160);
    const empty = try desk.notes.create(a, "", "Empty", "");
    try std.testing.expectEqualStrings("", (try desk.notes.snippet(a, empty)).?);
    // Cut in the middle of a character: still valid text.
    const accents = try desk.notes.create(a, "", "Accents", "é" ** 200);
    try std.testing.expect(std.unicode.utf8ValidateSlice((try desk.notes.snippet(a, accents)).?));

    _ = try pixel.folder.putBytes("Notes/Remote.md", "only on the phone", null);
    try std.testing.expect(try desk.folder.manifest.merge(pixel.folder.manifest.get("Notes/Remote.md").?));
    for (try desk.notes.list(a)) |n| {
        if (std.mem.eql(u8, n.title, "Remote")) try std.testing.expect((try desk.notes.snippet(a, n)) == null);
    }
}

/// What a sync round does to `into`: merges every entry of `from`.
fn pull(into: *Fixture, from: *Fixture) !void {
    for (from.folder.manifest.entries.values()) |e| _ = try into.folder.manifest.merge(e);
}

fn copyCount(arena: Allocator, notes: *Notes) !usize {
    var n: usize = 0;
    for (try notes.list(arena)) |note| {
        if (note.conflict_of != null) n += 1;
    }
    return n;
}

test "notes: two devices share a note, see each other's edits and keep concurrent ones" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    var pixel: Fixture = undefined;
    try pixel.open(0x55, "Pixel");
    defer pixel.close();
    const a = desk.arena();

    // Created on one device, listed on the other.
    const made = try desk.notes.create(a, "", "Plan", "v1");
    try pull(&pixel, &desk);
    const seen = try pixel.notes.list(a);
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("Desk", seen[0].author);
    try std.testing.expectEqualSlices(u8, &made.cid, &seen[0].cid);

    // Edited on the other; the first device's save from before the edit arrived is refused.
    const edited = try pixel.notes.save(a, made.path, "v2 from the phone", made.cid);
    try pull(&desk, &pixel);
    try std.testing.expectError(error.Changed, desk.notes.save(a, made.path, "stale", made.cid));
    try std.testing.expectEqualSlices(u8, &edited.cid, &desk.folder.fileInfo(made.path).?.cid);

    // Edited on both with no contact between: one conflict copy, the same on both.
    const mine = try desk.notes.save(a, made.path, "desk offline edit", edited.cid);
    _ = try pixel.notes.save(a, made.path, "phone offline edit", edited.cid);
    try pull(&desk, &pixel);
    try pull(&pixel, &desk);
    try std.testing.expectEqual(@as(usize, 1), try copyCount(a, &desk.notes));
    try std.testing.expectEqual(@as(usize, 1), try copyCount(a, &pixel.notes));
    try std.testing.expectEqual(@as(usize, 2), (try desk.notes.list(a)).len);
    try std.testing.expectEqualSlices(u8, &desk.folder.manifest.digest(), &pixel.folder.manifest.digest());

    // Twenty edits while the phone is away: no copy when it comes back. (The
    // phone holds a version the desk wrote, so the desk's own clock orders them.)
    const long = try desk.notes.create(a, "", "Long", "first");
    try pull(&pixel, &desk);
    var base = long.cid;
    for (0..20) |i| {
        const text = try std.fmt.allocPrint(a, "edit {d}", .{i});
        base = (try desk.notes.save(a, long.path, text, base)).cid;
    }
    _ = mine;
    try pull(&pixel, &desk);
    try std.testing.expectEqual(@as(usize, 1), try copyCount(a, &pixel.notes));
    try std.testing.expectEqual(@as(usize, 3), (try pixel.notes.list(a)).len);
    try std.testing.expectEqualSlices(u8, &base, &pixel.folder.fileInfo(long.path).?.cid);
}

test "notes: only paths under Notes/ are notes" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    _ = try f.folder.putBytes("Photos/2026-10-28 17-49-03 trip.txt", "not a note", null);
    const cid = f.folder.fileInfo("Photos/2026-10-28 17-49-03 trip.txt").?.cid;
    const other = "Photos/2026-10-28 17-49-03 trip.txt";
    try std.testing.expectError(error.NotANote, f.notes.save(a, other, "x", cid));
    try std.testing.expectError(error.NotANote, f.notes.read(a, other));
    try std.testing.expectError(error.NotANote, f.notes.get(a, other));
    try std.testing.expectError(error.NotANote, f.notes.rename(a, other, "x", cid));
    try std.testing.expectError(error.NotANote, f.notes.moveTo(a, other, "Work"));
    try std.testing.expectError(error.NotANote, f.notes.remove(other));
    try std.testing.expectError(error.NotANote, f.notes.setPinned(other, true));
    try std.testing.expectError(error.NotANote, f.notes.keepBoth(a, other, "x"));
    try std.testing.expectError(error.NotANote, f.notes.restore(a, .{ .path = other, .cid = cid, .size = 1, .author_id = cid, .pinned = false }));
    try std.testing.expectError(error.NotANote, f.notes.save(a, "Notes", "x", cid));
    try std.testing.expectError(error.NotANote, f.notes.save(a, "Notesx/a.md", "x", cid));
    try std.testing.expectError(error.NotANote, f.notes.save(a, "Notes/../Photos/a.md", "x", cid));
    // Nothing happened to it.
    try std.testing.expect(f.folder.fileInfo(other) != null);
    try std.testing.expectEqualSlices(u8, &cid, &f.folder.fileInfo(other).?.cid);
}

test "notes: a file that is not UTF-8 is not text" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    _ = try f.folder.putBytes("Notes/binary.md", "\xff\xfe\x00bin", null);
    try std.testing.expectError(error.NotText, f.notes.read(a, "Notes/binary.md"));
}

test "notes: saving a .txt that is not a legacy name keeps its name" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    _ = try f.folder.putBytes("Notes/todo.txt", "one", null);
    const cid = f.folder.fileInfo("Notes/todo.txt").?.cid;
    const saved = try f.notes.save(a, "Notes/todo.txt", "two", cid);
    try std.testing.expectEqualStrings("Notes/todo.txt", saved.path);
    try std.testing.expect(f.folder.fileInfo("Notes/todo.md") == null);
}

test "notes: a pin that cannot follow a stored rename does not fail it" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Alpha", "text");
    try f.notes.setPinned(note.path, true);
    // The pins file can no longer be read (here: it is a folder).
    const as_folder = try std.fmt.allocPrint(std.testing.allocator, "{s}.d", .{f.notes.pins_path});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, as_folder);
    std.testing.allocator.free(f.notes.pins_path);
    f.notes.pins_path = as_folder;
    const renamed = try f.notes.rename(a, note.path, "Beta", note.cid);
    try std.testing.expectEqualStrings("Notes/Beta.md", renamed.path);
    try std.testing.expect(f.folder.fileInfo("Notes/Alpha.md") == null);
    // The caller gets the stored note, not an error for a stored move.
    try std.testing.expectEqualSlices(u8, &note.cid, &renamed.cid);
}

test "notes: an oversize pins file is moved aside, not fatal" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    _ = try f.notes.create(a, "", "One", "1");
    const junk = try std.testing.allocator.alloc(u8, max_pins_file + 10);
    defer std.testing.allocator.free(junk);
    @memset(junk, 'x');
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = f.notes.pins_path, .data = junk });
    const listing = try f.notes.list(a);
    try std.testing.expectEqual(@as(usize, 1), listing.len);
    try std.testing.expect(!listing[0].pinned);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, f.notes.pins_path, .{}));
    var found = false;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, f.dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, "notes-pinned.corrupt-")) found = true;
    }
    try std.testing.expect(found);
    // And pinning works again.
    try f.notes.setPinned(listing[0].path, true);
    try std.testing.expect((try f.notes.list(a))[0].pinned);
}

test "notes: the largest legal pins file can be read back" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    var pins: std.ArrayList(Notes.Pin) = .empty;
    const long = "Notes/" ++ "d" ** 250 ++ "/" ++ "d" ** 250 ++ "/" ++ "d" ** 250 ++ "/" ++ "d" ** 240 ++ ".md";
    try std.testing.expect(manifest_mod.validPath(long));
    for (0..max_pins) |_| try pins.append(a, .{ .path = long, .cid = [_]u8{3} ** 32 });
    f.notes.pins_mutex.lock();
    try f.notes.storePins(pins.items);
    const loaded = try f.notes.loadPins(a);
    f.notes.pins_mutex.unlock();
    try std.testing.expectEqual(@as(usize, max_pins), loaded.len);
}

test "notes: a pin is not taken over by a look-alike when its note is deleted" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const doomed = try f.notes.create(a, "", "Same", "same text");
    _ = try f.notes.create(a, "Work", "Same", "something else"); // same name, other notebook
    _ = try f.notes.create(a, "", "Twin", "same text"); // same content
    _ = try f.notes.create(a, "", "Other", "other");
    try f.notes.setPinned(doomed.path, true);
    // Deleted on another device.
    try f.folder.remove(doomed.path);
    for (try f.notes.list(a)) |n| try std.testing.expect(!n.pinned);
    try std.testing.expectEqual(@as(usize, 0), (try std.Io.Dir.cwd().readFileAlloc(std.testing.io, f.notes.pins_path, a, .limited(4096))).len);
}

test "notes: the list is not limited to a number of folders" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    for (0..230) |i| {
        const path = try std.fmt.allocPrint(a, "Notes/book {d}/n.md", .{i});
        _ = try f.folder.putBytes(path, "x", null);
    }
    try std.testing.expectEqual(@as(usize, 230), (try f.notes.list(a)).len);
    try std.testing.expectEqual(@as(usize, 230), (try f.notes.notebooks(a)).len);
}

test "notes: files that are not notes make no notebook" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    _ = try f.folder.putBytes("Notes/Pictures/pic.png", "png", null);
    _ = try f.notes.create(a, "Work", "Real", "x");
    const books = try f.notes.notebooks(a);
    try std.testing.expectEqual(@as(usize, 1), books.len);
    try std.testing.expectEqualStrings("Work", books[0]);
}

test "notes: a search keeps only its snippets, not the notes it read" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();

    const body = try std.testing.allocator.alloc(u8, 400 * 1024);
    defer std.testing.allocator.free(body);
    @memset(body, 'a');
    for (0..4) |i| {
        var title: [8]u8 = undefined;
        _ = try f.notes.create(f.arena(), "", try std.fmt.bufPrint(&title, "Big {d}", .{i}), body);
    }
    _ = try f.notes.create(f.arena(), "", "Needle", "a needle in " ++ "a" ** 200);
    var search_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer search_arena.deinit();
    const hits = try f.notes.search(search_arena.allocator(), "needle in", 10);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    // 1.6 MB of text was read; the request holds a few hundred bytes of it.
    try std.testing.expect(search_arena.queryCapacity() < 64 * 1024);
}

test "notes: observers hear of a change under Notes/ once" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const Counter = struct {
        n: usize = 0,
        fn bump(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
        }
    };
    var counter: Counter = .{};
    try f.notes.attach();
    try f.notes.subscribe(.{ .ctx = &counter, .runFn = Counter.bump });
    // What the folder's thread does after a round that merged something.
    f.folder.on_change.run();
    try std.testing.expectEqual(@as(usize, 0), counter.n); // nothing under Notes/ changed
    _ = try f.notes.create(a, "", "New", "x");
    f.folder.on_change.run();
    try std.testing.expectEqual(@as(usize, 1), counter.n);
    f.folder.on_change.run();
    try std.testing.expectEqual(@as(usize, 1), counter.n); // told once

    var seen = f.folder.digestUnder("Notes/");
    try std.testing.expect(!f.notes.changedSince(&seen));
    _ = try f.notes.create(a, "", "Another", "y");
    try std.testing.expect(f.notes.changedSince(&seen));
    try std.testing.expect(!f.notes.changedSince(&seen));
}

test "notes: the after-sync pass renames legacy notes once per change" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    try f.notes.attach();
    _ = try f.folder.putBytes("Notes/2026-10-28 17-49-03 First.txt", "1", null);
    f.folder.after_sync.run();
    try std.testing.expect(f.folder.fileInfo("Notes/First.md") != null);
    try std.testing.expect(f.folder.fileInfo("Notes/2026-10-28 17-49-03 First.txt") == null);
    // Unchanged since the pass: no listing at all (a note that cannot be
    // renamed is not retried until something changes).
    const digest = f.notes.migrated_digest.?;
    f.folder.after_sync.run();
    try std.testing.expectEqualSlices(u8, &digest, &f.notes.migrated_digest.?);
    _ = try f.folder.putBytes("Notes/2026-10-29 08-00-00 Second.txt", "2", null);
    f.folder.after_sync.run();
    try std.testing.expect(f.folder.fileInfo("Notes/Second.md") != null);
    _ = a;
}

test "notes: keep both names the copy as the folder names a conflict" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    const a = desk.arena();

    const note = try desk.notes.create(a, "Work", "Plan", "theirs");
    const copy = try desk.notes.keepBoth(a, note.path, "mine");
    try std.testing.expectEqualStrings("Notes/Work/Plan (conflict from Desk).md", copy.path);
    try std.testing.expectEqualStrings("Notes/Work/Plan.md", copy.conflict_of.?);
    const again = try desk.notes.keepBoth(a, note.path, "mine 2");
    try std.testing.expectEqualStrings("Notes/Work/Plan (conflict from Desk 2).md", again.path);
    // Listed under its note.
    var grouped: usize = 0;
    for (try desk.notes.list(a)) |n| {
        if (n.conflict_of) |base| {
            try std.testing.expectEqualStrings(note.path, base);
            grouped += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), grouped);
}

test "notes: resolving a conflict copy is one checked step" {
    var desk: Fixture = undefined;
    try desk.open(0x44, "Desk");
    defer desk.close();
    const a = desk.arena();

    const note = try desk.notes.create(a, "", "Plan", "the note\n\n");
    const copy = try desk.notes.keepBoth(a, note.path, "  the copy");
    const base: Notes.Ref = .{ .path = note.path, .cid = note.cid };
    const copy_ref: Notes.Ref = .{ .path = copy.path, .cid = copy.cid };

    // Not a copy of that note.
    const other = try desk.notes.create(a, "", "Other", "o");
    try std.testing.expectError(error.NotAConflictCopy, desk.notes.resolveCopy(a, copy_ref, .{ .path = other.path, .cid = other.cid }, .append));
    // The note changed since the user looked: nothing stored, copy kept.
    const edited = try desk.notes.save(a, note.path, "edited elsewhere", note.cid);
    try std.testing.expectError(error.Changed, desk.notes.resolveCopy(a, copy_ref, base, .append));
    try std.testing.expect(desk.folder.fileInfo(copy.path) != null);
    try std.testing.expectEqualStrings("edited elsewhere", (try desk.notes.read(a, note.path)).text);

    // Append: the note, a blank line, the copy; the copy is gone.
    const fresh: Notes.Ref = .{ .path = note.path, .cid = edited.cid };
    const appended = try desk.notes.resolveCopy(a, copy_ref, fresh, .append);
    try std.testing.expect(!appended.outcome.changed);
    try std.testing.expectEqualStrings("edited elsewhere\n\nthe copy", (try desk.notes.read(a, note.path)).text);
    try std.testing.expect(desk.folder.fileInfo(copy.path) == null);
    try std.testing.expectEqualStrings(copy.path, appended.removed.?.path);

    // Use the copy: its text replaces the note's.
    const copy2 = try desk.notes.keepBoth(a, note.path, "replacement");
    const now = desk.folder.fileInfo(note.path).?.cid;
    const used = try desk.notes.resolveCopy(a, .{ .path = copy2.path, .cid = copy2.cid }, .{ .path = note.path, .cid = now }, .use_copy);
    try std.testing.expectEqualStrings("replacement", (try desk.notes.read(a, note.path)).text);
    try std.testing.expect(used.removed != null);
    try std.testing.expect(desk.folder.fileInfo(copy2.path) == null);

    // Discard: only the copy goes, and it can be restored.
    const copy3 = try desk.notes.keepBoth(a, note.path, "unwanted");
    const discarded = try desk.notes.resolveCopy(a, .{ .path = copy3.path, .cid = copy3.cid }, .{ .path = note.path, .cid = desk.folder.fileInfo(note.path).?.cid }, .discard);
    try std.testing.expectEqualStrings("replacement", (try desk.notes.read(a, note.path)).text);
    const back = try desk.notes.restore(a, discarded.removed.?);
    try std.testing.expectEqualStrings("unwanted", (try desk.notes.read(a, back.path)).text);
    // The copy changed since the user looked.
    try std.testing.expectError(error.Changed, desk.notes.resolveCopy(a, .{ .path = copy3.path, .cid = note.cid }, .{ .path = note.path, .cid = now }, .discard));
}

test "notes: the changed answer is the current note, or none when it is gone" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const note = try f.notes.create(a, "", "Plan", "v1");
    const answer = f.notes.changedOutcome(a, note.path);
    try std.testing.expect(answer.changed);
    try std.testing.expectEqualStrings("Plan", answer.note.?.title);
    _ = try f.notes.remove(note.path);
    try std.testing.expect(f.notes.changedOutcome(a, note.path).note == null);
    try std.testing.expect(f.notes.changedOutcome(a, "Photos/x.md").note == null);
}

test "notes: shared text becomes a note with a title" {
    var f: Fixture = undefined;
    try f.open(0x44, "Desk");
    defer f.close();
    const a = f.arena();

    const first_line = try f.notes.createFromShare(a, .{ .text = "\n\nFirst line\nsecond" });
    try std.testing.expectEqualStrings("First line", first_line.title);
    try std.testing.expectEqualStrings("\n\nFirst line\nsecond", (try f.notes.read(a, first_line.path)).text);
    const subject = try f.notes.createFromShare(a, .{ .text = "body", .subject = "A page" });
    try std.testing.expectEqualStrings("A page", subject.title);
    const url = try f.notes.createFromShare(a, .{ .url = "https://example.com" });
    try std.testing.expectEqualStrings("https: example.com", url.title);
    try std.testing.expectEqualStrings("https://example.com", (try f.notes.read(a, url.path)).text);
    const named = try f.notes.createFromShare(a, .{ .text = "contents", .name = "meeting.md" });
    try std.testing.expectEqualStrings("meeting", named.title);
    const upper = try f.notes.createFromShare(a, .{ .text = "contents", .name = "notes.TXT" });
    try std.testing.expectEqualStrings("notes", upper.title);
    const empty = try f.notes.createFromShare(a, .{});
    try std.testing.expectEqualStrings("Untitled", empty.title);
    const long = try f.notes.createFromShare(a, .{ .text = "x" ** 300 });
    try std.testing.expectEqual(@as(usize, 120), long.title.len);
    try std.testing.expectError(error.NotText, f.notes.createFromShare(a, .{ .text = "\xff\xfe" }));
}
