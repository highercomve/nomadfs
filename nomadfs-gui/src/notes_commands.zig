//! The Notes commands: thin wrappers over the notes service (src/fs/notes.zig),
//! which the node owns (`node.notes`). Naming, saving, conflicts, pins and the
//! rules about what a note is all live there; these parse the page's
//! arguments, call it and turn CIDs into hex text.

const std = @import("std");
const nomadfs = @import("nomadfs");
const commands = @import("commands.zig");

const fs = nomadfs.fs;
const Notes = fs.notes.Notes;

pub const NotesArgs = struct {
    notebook: []const u8 = "",
    title: []const u8 = "",
    path: []const u8 = "",
    text: []const u8 = "",
    /// The CID (hex) the editor loaded or last saved.
    base: []const u8 = "",
    query: []const u8 = "",
    pinned: bool = false,
    /// note_restore: what note_delete returned.
    cid: []const u8 = "",
    size: u64 = 0,
    author_id: []const u8 = "",
    /// note_resolve_copy: the conflict copy and the CID the user saw of it,
    /// and what to do (`use_copy`, `append` or `discard`).
    copy: []const u8 = "",
    copy_cid: []const u8 = "",
    action: []const u8 = "",
    /// note_from_share: text shared into the app.
    url: []const u8 = "",
    subject: []const u8 = "",
    name: []const u8 = "",
};

// @atlas allow: duplicate_shape: fs.Notes.Note for the page: CIDs as hex text.
pub const NoteView = struct {
    path: []const u8,
    title: []const u8,
    notebook: []const u8,
    cid: []const u8,
    size: u64,
    mtime: u64,
    author: []const u8,
    author_id: []const u8,
    pinned: bool,
    conflict_of: ?[]const u8,
    legacy: bool,
    editable: bool,
    /// The start of the text; null when its blocks aren't on this device.
    snippet: ?[]const u8,
};
pub const NotesList = struct { notes: []NoteView, notebooks: [][]const u8 };
pub const NoteRead = struct { text: []u8, cid: []const u8 };
/// `changed`: the note is no longer the one the editor had (nothing was
/// stored); `note` is then the current one, or null if it is gone.
pub const NoteResult = struct { changed: bool, note: ?NoteView };
// @atlas allow: duplicate_shape: fs.Notes.Removed for the page: CIDs as hex text.
pub const NoteDeleted = struct { path: []const u8, cid: []const u8, size: u64, author_id: []const u8, pinned: bool };
/// A conflict copy settled: the note as it is, and the copy as it was
/// deleted (null: it could not be deleted).
pub const NoteMerged = struct { changed: bool, note: ?NoteView, removed: ?NoteDeleted };

/// The notes service of the running node, for one command. The node is
/// pinned (not g_mutex held), so a note read from a slow device doesn't
/// stall the rest of the app; pair with close().
const Session = struct {
    service: *Notes,

    fn open() !Session {
        const handle = commands.mediaAcquire() orelse return error.NotRunning;
        errdefer commands.mediaRelease();
        const service = handle.node.notes orelse return error.StorageDisabled;
        return .{ .service = service };
    }

    fn close(self: *Session) void {
        _ = self;
        commands.mediaRelease();
    }

    fn view(self: *Session, gpa: std.mem.Allocator, note: Notes.Note) !NoteView {
        return .{
            .path = note.path,
            .title = note.title,
            .notebook = note.notebook,
            .cid = try commands.hexAlloc(gpa, &note.cid),
            .size = note.size,
            .mtime = note.mtime,
            .author = note.author,
            .author_id = try commands.hexAlloc(gpa, &note.author_id),
            .pinned = note.pinned,
            .conflict_of = note.conflict_of,
            .legacy = note.legacy,
            .editable = note.editable,
            .snippet = try self.service.snippet(gpa, note),
        };
    }

    fn result(self: *Session, gpa: std.mem.Allocator, outcome: Notes.Outcome) !NoteResult {
        return .{ .changed = outcome.changed, .note = if (outcome.note) |n| try self.view(gpa, n) else null };
    }

    fn deleted(gpa: std.mem.Allocator, removed: Notes.Removed) !NoteDeleted {
        return .{
            .path = try gpa.dupe(u8, removed.path),
            .cid = try commands.hexAlloc(gpa, &removed.cid),
            .size = removed.size,
            .author_id = try commands.hexAlloc(gpa, &removed.author_id),
            .pinned = removed.pinned,
        };
    }
};

/// `notes_list`: every note and file under Notes/, pinned first, newest
/// first, and the notebooks that hold a note. (Legacy notes this device
/// wrote are renamed by the node, not here.)
pub fn list(gpa: std.mem.Allocator) !NotesList {
    var session = try Session.open();
    defer session.close();
    const notes = try session.service.list(gpa);
    const out = try gpa.alloc(NoteView, notes.len);
    for (notes, out) |n, *o| o.* = try session.view(gpa, n);
    return .{ .notes = out, .notebooks = try fs.notes.notebooksOf(gpa, notes) };
}

/// `note_read { path }`: the text and the CID to pass back as `base`.
pub fn read(gpa: std.mem.Allocator, args: NotesArgs) !NoteRead {
    var session = try Session.open();
    defer session.close();
    const loaded = try session.service.read(gpa, args.path);
    return .{ .text = loaded.text, .cid = try commands.hexAlloc(gpa, &loaded.cid) };
}

/// `note_create { notebook, title, text }`.
pub fn create(gpa: std.mem.Allocator, args: NotesArgs) !NoteView {
    var session = try Session.open();
    defer session.close();
    return session.view(gpa, try session.service.create(gpa, args.notebook, args.title, args.text));
}

/// `note_from_share { text, url, subject, name }`: text shared into the app.
pub fn fromShare(gpa: std.mem.Allocator, args: NotesArgs) !NoteView {
    var session = try Session.open();
    defer session.close();
    const note = try session.service.createFromShare(gpa, .{ .text = args.text, .url = args.url, .subject = args.subject, .name = args.name });
    return session.view(gpa, note);
}

/// `note_save { path, text, base }`: stored only if the note is still `base`.
pub fn save(gpa: std.mem.Allocator, args: NotesArgs) !NoteResult {
    var session = try Session.open();
    defer session.close();
    const note = session.service.save(gpa, args.path, args.text, try commands.parseHex32(args.base)) catch |err| switch (err) {
        error.Changed => return session.result(gpa, session.service.changedOutcome(gpa, args.path)),
        else => return err,
    };
    return session.result(gpa, .{ .changed = false, .note = note });
}

/// `note_rename { path, title, base }`.
pub fn rename(gpa: std.mem.Allocator, args: NotesArgs) !NoteResult {
    var session = try Session.open();
    defer session.close();
    const note = session.service.rename(gpa, args.path, args.title, try commands.parseHex32(args.base)) catch |err| switch (err) {
        error.Changed => return session.result(gpa, session.service.changedOutcome(gpa, args.path)),
        else => return err,
    };
    return session.result(gpa, .{ .changed = false, .note = note });
}

/// `note_move { path, notebook }`.
pub fn move(gpa: std.mem.Allocator, args: NotesArgs) !NoteView {
    var session = try Session.open();
    defer session.close();
    return session.view(gpa, try session.service.moveTo(gpa, args.path, args.notebook));
}

/// `note_delete { path }`: what `note_restore` needs to undo it.
pub fn delete(gpa: std.mem.Allocator, args: NotesArgs) !NoteDeleted {
    var session = try Session.open();
    defer session.close();
    return Session.deleted(gpa, try session.service.remove(args.path));
}

/// `note_restore { path, cid, size, author_id, pinned }`.
pub fn restore(gpa: std.mem.Allocator, args: NotesArgs) !NoteView {
    var session = try Session.open();
    defer session.close();
    const note = try session.service.restore(gpa, .{
        .path = args.path,
        .cid = try commands.parseHex32(args.cid),
        .size = args.size,
        .author_id = try commands.parseHex32(args.author_id),
        .pinned = args.pinned,
    });
    return session.view(gpa, note);
}

/// `note_pin { path, pinned }`: on this device only.
pub fn pin(gpa: std.mem.Allocator, args: NotesArgs) !void {
    _ = gpa;
    var session = try Session.open();
    defer session.close();
    try session.service.setPinned(args.path, args.pinned);
}

/// `notes_search { query }`: titles, then the text of notes held here.
pub fn search(gpa: std.mem.Allocator, args: NotesArgs) ![]Notes.Hit {
    var session = try Session.open();
    defer session.close();
    return session.service.search(gpa, args.query, 100);
}

/// `note_keep_both { path, text }`: the editor's text becomes a conflict
/// copy next to the note.
pub fn keepBoth(gpa: std.mem.Allocator, args: NotesArgs) !NoteView {
    var session = try Session.open();
    defer session.close();
    return session.view(gpa, try session.service.keepBoth(gpa, args.path, args.text));
}

/// `note_resolve_copy { copy, copy_cid, path, base, action }`: settles a
/// conflict copy of the note at `path` (see `Notes.resolveCopy`).
pub fn resolveCopy(gpa: std.mem.Allocator, args: NotesArgs) !NoteMerged {
    var session = try Session.open();
    defer session.close();
    const how = std.meta.stringToEnum(Notes.Resolution, args.action) orelse return error.InvalidArgument;
    const copy: Notes.Ref = .{ .path = args.copy, .cid = try commands.parseHex32(args.copy_cid) };
    const base: Notes.Ref = .{ .path = args.path, .cid = try commands.parseHex32(args.base) };
    const merged = session.service.resolveCopy(gpa, copy, base, how) catch |err| switch (err) {
        error.Changed => {
            const answer = try session.result(gpa, session.service.changedOutcome(gpa, args.path));
            return .{ .changed = true, .note = answer.note, .removed = null };
        },
        else => return err,
    };
    const answer = try session.result(gpa, merged.outcome);
    return .{
        .changed = false,
        .note = answer.note,
        .removed = if (merged.removed) |r| try Session.deleted(gpa, r) else null,
    };
}
