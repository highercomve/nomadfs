# Notes

Notes are Markdown files under the swarm folder's `Notes/` path, and
`src/fs/notes.zig` is the one service that knows what that means. The app
calls it; so will the command line and the mobile API. Nothing about notes
is in a front end beyond presentation.

## How a note maps onto the swarm folder

- `Notes/<title>.md`. The **title is the file name** without the extension, so
  the mount, WebDAV and any editor see readable names. A title is trimmed,
  control characters, `/` and `\` become one space, and it is cut at 120
  bytes on a character boundary (`sanitizeTitle`). Empty is "Untitled".
- A **notebook is a folder**: `Notes/Work/Standup.md`. A notebook is nothing
  but a path prefix, so one with no notes in it does not exist; moving a note
  to a new name creates it.
- `.txt` files in `Notes/` are notes too. Notes written before this service
  were `YYYY-MM-DD HH-MM-SS title.txt`; the list shows them by title, and
  `migrateLegacy` renames the ones this device wrote to `title.md`, keeping the
  modified time. Notes another device wrote are left to that device, so two
  devices never race on the same rename. Saving a legacy note renames it.
- Other extensions are listed as files, not notes.
- Created time, modified time and "last edited on <device>" come from the
  manifest entry. Nothing is stored inside the file.

## Saving

`save(path, text, base)` is a compare-and-set: it stores the text only if
the file's current CID is `base`, the one the editor loaded or last saved.
Otherwise it returns `error.Changed` and stores nothing (`SwarmFolder.putBytes`
re-checks under the manifest lock, after hashing, so a lost race costs only
unreferenced blocks). `rename` and `moveTo` use the same check through
`moveIfUnchanged`. The editor answers a `Changed` with a choice: look at the
other version, keep both, or replace it on purpose by saving again with the
CID it just saw.

Two devices that edit while apart never see `Changed`; the manifest keeps
both (see `fs/manifest.zig` and the swarm CRDT page): the higher version keeps
the path and the other becomes `Title (conflict from Device).md`. The list
points such a copy at its note (`conflict_of`).

### Resolving a conflict copy

`keepBoth(path, text)` stores the editor's text as `Title (conflict from
<this device>).md` next to the note (a second one is `... from Desk 2).md`), the
name the manifest gives a concurrent edit, so the list groups it under its
note (`conflictOf`, `manifest.conflict_marker`). `resolveCopy(copy, base, how)`
settles a copy: `use_copy` saves its text over the note, `append` puts it after
the note's text, `discard` deletes it. Both `Ref`s carry the CID the user saw;
the one compare-and-set is the `save` (`error.Changed` otherwise), then the
copy is deleted. A copy that cannot be deleted after a good merge is reported
(`removed == null`), not an error. The page only shows the two texts and
passes the choice.

### Blocks of old versions

Every save writes new blocks and leaves the previous version's blocks in the
store. Chunking is content-defined, so a small edit shares most blocks with the
version before, but the changed ones stay. What is done:

- `putBytes` checks the base, the folder and the gate *before* building the
  blocks, so a stale save, a taken name (`create` tries "Title", "Title 2", ...)
  or a gated folder (`NotSynced`) stores nothing. Only a race between that
  check and the edit under the lock can still leave unreferenced blocks.

What is not done, and why: nothing is deleted or demoted. The store has no
delete and no reference counts (`storage/engine.zig` only moves kept blocks
into the evictable read cache, `demoteExcept`, once at start for blocks from
before the cache existed). Content addressing shares blocks between files: an
old version's blocks may also be another note's (a copy, the same text), a
share's, a backed-up file's (`backed_up`), a replica the keeper holds for the
cluster, or a blob stored by `put_file` that no manifest entry names. Deleting
one such block loses data, so a sweep must know every reference first.

Design for a real collection, for a later change:

1. Roots: the CIDs of every live manifest entry (any author), `backed_up`, the
   shares' roots, the keeper's copies, and a new small list of blobs stored by
   `put_file` (recorded where they are stored; without it they would look
   unreferenced).
2. Walk each root (`storage/dag/walk.zig` `addStoredReachable`) into one set.
3. Demote, never delete: move every kept block outside the set, and older than a
   day (a block just built by a save in flight is not yet in a manifest), into
   the read cache with `demoteExcept`. The cache limit then evicts the oldest
   unread ones; with no limit they stay, which is only growth, not loss.
4. Run it in the node, after `sortLegacyCache`'s conditions (shares scanned),
   off the sync thread, and at most daily.

## Same-device ordering

A device's own edits are sequential, so two versions from the same device are
ordered by their Lamport clock (`Entry.descendsFrom`), however many edits
apart. Without that, a device that edited a file more than eight times
(`history_len`) while a peer was away made the peer create a false conflict
copy of its own stale version when it came back. Autosave makes that common.

The clock must never go back for a device ID. It is persisted twice: with
the manifest, and in `<manifest>.clock`, a decimal bound above every clock value
this device has used. The bound is reserved ahead (about a million values at a
time, checked before each edit, so a write is rare) and written before any edit
that uses it exists, so a crash inside the one-second manifest batching, or a
lost manifest, cannot take the clock below a version a peer already pulled. At
start the clock is the larger of the two. A clock file that cannot be read is
moved aside (`.corrupt-<time>`) and counts as missing.

Only when *both* files are missing (a fresh device, or both lost with the key
kept) can the clock have restarted, so only then local edits wait
(`error.NotSynced`, `awaiting_pull`). The wait ends when a sync round has merged
a reached peer's manifest (a peer whose manifest could not be read does not
count, and neither does a round that knew no peer yet), or after 60 seconds
(`alone_grace_ms`): a device with no peers at all has nothing to pull from. A
brand-new device on its own therefore cannot save its first note for the first
minute.

## Pins and the rename race

Pins belong to the device. They live in `<storage_path>.notes-pinned`, next to
the node's other per-device state (`<path>\t<cid hex>`, at most 500, written to
a temporary file and renamed), never in the swarm folder. The node owns the one
service (`node.notes`), so every front end of a device sees the same pins. A
pin follows its note: a local rename or move rewrites it. When the pinned path is
gone, the service asks the folder whether it was *moved* (`movedFrom`: a move
writes the new path and then the old path's tombstone as the device's next
version, so the new entry has the version just before the tombstone's); a pin goes
to such a note only if it also has the pin's last CID (refreshed on every list) or
the same file name. A path that was only deleted drops its pin, whatever other
notes look alike. A file that is too large to be a pins file is moved aside
(`.corrupt-<time>`) and the pins start empty; one that cannot be read or written
is logged and the list goes on without pins.

A rename on one device concurrent with an edit on another leaves the note at
both names: a rename is "write the new path, delete the old one", and an edit
beats a delete. The list shows both and the user deletes one.

## Known gap

The ordering rule covers one device's own edits. A version another device wrote
is known only while it is among the last eight in the entry's history. If the
desk adopts the phone's version of a note and then edits it more than eight
times before the phone syncs again, the phone sees the desk's newest version
without its own in the history and keeps its old text as a
`(conflict from Phone)` copy. Closing it takes a per-entry record of the newest
clock seen from each device instead of a short history; that changes the
manifest format, so it is not part of the notes work.

## The node owns the service

`Node.notes` is created next to the swarm folder and wired in `node.zig`:

- The swarm folder has two small fixed hook lists (`addChangeHook`, run after a
  round that merged something; `addAfterSyncHook`, after every round), both of
  the one `SwarmFolder.Hook` type. The backup import and the notes use them.
- `Notes.attach` registers the notes' own hooks. After a round that changed
  `Notes/` (`changedSince` compares the `Notes/` digest with the one last
  announced) the service calls its subscribers; the app subscribes once per
  node, when the node is opened, and only emits `notes://changed`.
- After every round `migrateIfNeeded` renames the legacy notes this device wrote
  (only when `Notes/` changed since the last complete pass), so a headless node
  does it too and no front end has to.
- Every public method that takes a path starts with `requireNote`: the path must
  be under `Notes/` and valid, else `error.NotANote`.
- `read` refuses a file that is not UTF-8 (`error.NotText`); `save` and
  `rename` answer a stale base with `error.Changed` and `changedOutcome` is the
  shape front ends return; `createFromShare` titles a note made from shared
  text; `notebooks` lists only folders holding an editable note.
- Search reads one note at a time into one reused buffer and keeps only the
  snippet, and stops after 64 MiB of text per search.
