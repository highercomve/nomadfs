# Chapter 5.3: Folder Backup

A device can ask the swarm to keep a copy of some of its shared folders: a phone's camera, its
screenshots, WhatsApp photos, or any other share. Every **swarm backup device** keeps those
copies, the same devices that keep a copy of the [swarm folder](./swarm.md). Code:
`src/fs/backup.zig`. Who counts as a member: [swarm membership](../security/pairing.md#swarm-membership).

## 1. Marking a folder

A share is marked with `backup = "<share name>"` in the config (repeatable), or with the
**Back up** toggle on a shared folder in the app. The app's Camera, Screenshots and WhatsApp
presets come with it on. `ShareIndex.setBackup` keeps the marks apart from the shares themselves,
so re-adding a share keeps its mark.

## 2. What a device tells the swarm

The `SHARES` reply carries a `backup` field next to the listing (`backup.encodeInfo`):

```
[u8 version=1]
[u8 n]  n × [u8 len][share name]                       shares to keep
[u8 m]  m × [owner device ID 32][u8 len][share]        backups held here
            [source root 32][u64 synced_at]
```

- **Wanted** lists the marked shares that have a root, only while the device is on an unmetered
  network (`local_addrs.onUnmeteredNetwork`: on Android, a Wi-Fi or wired interface; elsewhere
  always), so a phone on mobile data is not pulled from.
- **Held** tells the swarm which backups this device keeps. `source_root` is the owner's share
  root it last copied, so the owner knows whether the copy is current.

## 3. The backup device (`FolderBackup`)

A thread started with the listener runs a round a minute while swarm backup is on:

1. For every known device, `GET_SHARES`. Only swarm members (devices in the trust store) are
   backed up.
2. For each wanted share whose root differs from the last copied one, copy it with the cluster
   layer's `keeper.copy` ([Chapter 4.4](../cluster/keeper.md)): every block through the fetcher,
   kept in the kept area (never evicted, see [the read cache](../storage/engine.md#the-read-cache))
   against the quota. File data already held is skipped without being read, so copying a large
   camera folder again reads only its index; an interrupted copy resumes. Deciding *what* to keep
   and the merge below are this module's; *how* blocks arrive is the cluster layer's.
3. **Merge** the new version into this device's own tree of the share (`backup.merge`): every
   entry of the new version, plus every entry of the previous tree the new version no longer
   has; folders of the same name merge recursively, otherwise the new entry wins. Files deleted
   at the source stay, so a phone can free space without losing a photo.
4. List the merged tree as a share named `<device> · <share> (backup)` (`ShareIndex.setHeld`),
   with the device named by its label in the trust store. Any device browses and restores from
   it like any share, while the phone is off. The held backups are saved in
   `<storage_path>.backups` and listed again after a restart.

## 4. On the source

The app's **Shared folders** page shows, under each marked folder, which backup devices hold a
copy and whether it is current (`backup_status`): *Backed up on Plex · Ridge*, *new files being
copied*, or *waiting for Wi-Fi*.

Reading those SHARES replies also tells the cluster layer who keeps whose folders
(`holders.noteKeeps`, [Chapter 4.2](../cluster/holders.md)): when the phone is off, opening its
photos from another device reads them from the backup device.

> **Not implemented yet:** per-photo "backed up" marks and **Free up space**, a charging-only
> option, backup away from home without Tailscale (needs a public relay), and encryption at rest.
> Turning a mark off stops new copies; copies already made stay on the backup devices.
