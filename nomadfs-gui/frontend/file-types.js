// What kind of a file a name names, and the icon to draw for it.

export const FILE_TYPES = {
  photo: ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "svg", "dng", "raw", "cr2", "nef", "arw", "tif", "tiff"],
  video: ["mp4", "mov", "mkv", "webm", "avi", "3gp", "wmv", "flv", "m4v", "ts"],
  audio: ["mp3", "m4a", "flac", "wav", "ogg", "aac", "opus", "wma", "aiff"],
  document: ["pdf", "doc", "docx", "txt", "md", "rtf", "odt", "xls", "xlsx", "csv", "ppt", "pptx", "epub"],
  archive: ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz"],
  code: ["zig", "rs", "js", "ts", "html", "css", "json", "py", "c", "cpp", "h", "sh", "yaml", "yml", "toml", "go"],
};

export function fileType(name, dir) {
  if (dir) return "Folder";
  const ext = (name.split(".").pop() || "").toLowerCase();
  if (FILE_TYPES.photo.includes(ext)) return "Photo";
  if (FILE_TYPES.video.includes(ext)) return "Video";
  if (FILE_TYPES.audio.includes(ext)) return "Audio";
  if (FILE_TYPES.document.includes(ext)) return "Document";
  if (FILE_TYPES.archive.includes(ext)) return "Archive";
  if (FILE_TYPES.code.includes(ext)) return "Code";
  return "File";
}

export function iconFor(name, dir) {
  if (dir) return "folder";
  const t = fileType(name, false);
  if (t === "Photo") return "image";
  if (t === "Video") return "video";
  if (t === "Audio") return "audio";
  return "file";
}
