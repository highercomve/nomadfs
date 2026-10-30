---
name: review
description: Review NomadFS code (a diff, a branch, files or the whole tree) in four lenses — Zig idioms and correctness, memory and resources, NASA/JPL Power of 10 adapted to Zig, and architecture (layers, domain modules, one shared service per feature for the CLI, the app and the mobile API). Use for any code review, before merging or releasing, or when asked to check that code is reusable and sits in the right layer.
---

# NomadFS code review

Works for any coding agent. Read the code, judge it against the four lenses
below, **verify every finding against the code** before reporting it, and write
the review as one file. Do not modify source files during a review.

## 1. Scope

- Default: the change under review, `git diff <base>...HEAD` (base: `main`, or the
  last release tag `git describe --tags --abbrev=0`). Also read the code around each
  change: a finding about a call needs its callee.
- A path, a branch or "the whole project" when asked.
- Note what you did **not** read, so the reader knows the review's reach.

## 2. Lens A: Zig idioms and correctness (Zig 0.16)

- **Errors**: every fallible call handled; `errdefer` releases what a failing
  function already acquired; `catch {}` / `catch continue` / `_ =` only where
  dropping the error is right, with a comment saying why.
- **Ownership**: who frees each allocation is clear from the API (doc comment
  "caller-owned", an `allocator` parameter, a `deinit`); arenas only for
  request-scoped data; nothing from an arena or a stack buffer stored in a
  long-lived struct.
- **Slices and pointers**: no slice into an `ArrayList`, map or snapshot that may
  be reallocated or freed while used; no pointer to a stack value kept past its
  scope; `@ptrCast`/`@alignCast` only on `*anyopaque` contexts built for that type.
- **Integers**: `@intCast`/`@truncate` only on values proven in range; untrusted
  sizes (network, disk) checked before use; `+|`, `-|` where saturation is meant.
- **Concurrency**: what each mutex guards is written next to it; no blocking I/O or
  network call under a lock other code needs; lock order is consistent; flags read
  from several threads are atomics; threads are joined before what they use is freed.
- **Untrusted input**: everything decoded from a peer or a file is bounded (sizes,
  counts, depth) and validated before allocation or recursion.

## 3. Lens B: memory and resources

- Leaks on every error path (partially built arrays, half-initialised structs).
- Double frees, use after free, frees with the wrong allocator.
- File descriptors, connections and streams closed on every path.
- Bounded growth: caches, tables and queues have a cap and an eviction rule.
- Shutdown order: background threads stop before the objects they use are freed
  (check `deinit` order in `src/root.zig`).

## 4. Lens C: Power of 10, adapted to Zig

1. Simple control flow; no unbounded recursion (a tree walk from a peer needs a
   depth bound).
2. Every loop has an upper bound (retries, polling, walks over peer data).
3. No allocation driven by untrusted sizes; per-request and per-round allocation
   is bounded.
4. Functions short enough to read (about 60 lines); list the longest new ones.
5. Invariants asserted at trust boundaries (decoded messages, files loaded).
6. Data in the smallest scope.
7. Every return value checked (see Lens A, errors).
8. Comptime and metaprogramming kept simple.
9. Pointer discipline (see Lens A).
10. Builds clean in Debug and ReleaseSafe; tests pass (`zig build test`).

Be pragmatic: this is a personal filesystem, not flight software. Report what
matters for reliability.

## 5. Lens D: architecture, layers and reuse

NomadFS is organised as domain modules in layers. Each module owns one part of
the problem, speaks its own vocabulary, and depends only downward.

| Layer | Code | Owns (the "what") | Must not |
| :--- | :--- | :--- | :--- |
| Front ends | `src/main.zig` (CLI), `nomadfs-gui/` (app), `src/mobile/` (C API) | parsing input, presenting output | contain domain logic, or duplicate each other |
| Node (composition root) | `src/root.zig` | wiring modules together, lifecycles, the service API front ends call | hold feature logic that belongs in a module |
| Folders (meaning) | `src/fs/` | shares, the swarm manifest, folder trees, backup merge, read-ahead (which blocks next) | fetch blocks or copy DAGs itself |
| Distribution | `src/cluster/` | where blocks come from (fetcher), who holds what (holders), who keeps what (placement), copying (keeper) | know what a share, folder or manifest is |
| Devices | `src/device/` | identity, trust store, pairing, invites, signed policy | depend on folders or distribution |
| Storage | `src/storage/` | chunking, CIDs, DAG blocks, the block store | depend on anything above it |
| Transport | `src/net/` | connections, Noise, Yamux, the DHT, messages | decide what to fetch or keep |

Check:

- **Dependency direction**: `@import`s point down or sideways within a layer,
  never up (e.g. `cluster/` importing `fs/` is a defect; `fs/` calling `cluster/`
  is right). Upward needs go through an interface the lower layer defines (a
  context pointer plus function pointers, like `keeper.Provider`).
- **One service per feature**: a feature offered by more than one front end
  (pairing, invites, trusting and revoking devices, the read cache, swarm copies,
  backups, shares) is implemented **once**, in the core, and the CLI, the app and
  the mobile API call that one service. Look for the same steps in
  `src/main.zig`, `nomadfs-gui/src/commands.zig` and `src/mobile/api.zig`: each
  copy is a finding, with the service it should become.
- **State has one owner**: data a running node holds (the trust store, the policy,
  the config it acts on) is changed through that node's service, or the store
  must handle other writers safely. Two processes writing the same file without
  coordination is a defect.
- **Domain language**: names say what the domain says (a *holder*, a *share*, a
  *member*, a *copy*), the same word for the same thing across modules, and a
  module's public API reads like its domain, not like its implementation.
- **Cohesion and size**: a module or file that does several unrelated jobs
  (front-end command files are the usual suspects) should be split along domain
  lines; say where.
- **Lean network**: new messages are sent only on change or on demand, learn from
  traffic already flowing, and have bounded size; periodic per-file traffic is a
  defect. A message added for one feature should be one other features can reuse.
- **Tests at the right layer**: domain logic tested in its module with fakes for
  lower layers (e.g. the fetcher's fake transport); cluster tests for behaviour
  across devices.

## 6. How to run it

- Read the scope, then go lens by lens. If the agent can run sub-agents, one per
  lens in parallel is a good split; keep each at medium effort or below and give
  each this file and the scope. Otherwise do the lenses in order.
- For every candidate finding, open the code and confirm it: a concrete input or
  sequence that goes wrong, or the exact duplicated lines. Drop what you can't
  confirm, or mark it *unverified*.
- Run `zig build test` (and `zig build` in `nomadfs-gui/` when the app changed)
  if you can; report the result. A "failed command" line from a test that wrote to
  stderr is normal; the exit code is what counts.

## 7. The report

Write it to `.agents/review/<scope>/review.md` (e.g. `.agents/review/v0.3.0/`,
`.agents/review/cluster-layer/`). Start with a one-line verdict (approve / approve
with changes / rework), then the findings ranked by severity:

```
### [severity] Short title (lens)
- Where: path/file.zig:123 (and the other copies, for duplication)
- What goes wrong: the concrete scenario
- Fix: the change, and for architecture findings the module/service it belongs in
```

Severity: **critical** (data loss, crash, security), **high** (wrong behaviour in
normal use, layer violation that already caused a bug), **medium** (latent bug,
duplication, missing bound), **low** (clarity, small cleanups). End with what was
checked and found sound, and what was not covered.
