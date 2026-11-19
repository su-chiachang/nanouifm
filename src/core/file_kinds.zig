//! Extension tables: package extensions and the human "kind" description Finder shows.

const std = @import("std");

/// Directory extensions that macOS treats as a single opaque item (a "package"/bundle).
const package_exts = [_][]const u8{
    "app",       "bundle",   "framework", "plugin",      "xcodeproj", "xcworkspace",
    "photoslibrary", "musiclibrary", "tvlibrary", "kext",  "prefpane",  "saver",
    "qlgenerator", "mdimporter", "appex",  "xpc",        "playground", "xcassets",
    "pkg",       "mpkg",     "dSYM",      "rtfd",        "wdgt",      "lproj",
    "scptd",     "workflow", "action",    "component",   "docset",    "xcarchive",
    "xctest",    "imovielibrary", "fcpbundle", "logicx", "band",      "sparsebundle",
    "sparseimage", "download", "numbers", "pages",       "key",
};

/// Kinds of packages, where they differ from the generic "Package" (extension, description).
const package_kinds = [_]Kind{
    .{ "app", "Application" },
    .{ "bundle", "Bundle" },
    .{ "framework", "Framework" },
    .{ "plugin", "Plug-in" },
    .{ "xcodeproj", "Xcode project" },
    .{ "xcworkspace", "Xcode workspace" },
    .{ "photoslibrary", "Photos Library" },
    .{ "musiclibrary", "Music Library" },
    .{ "kext", "Kernel extension" },
    .{ "prefpane", "System Settings pane" },
    .{ "saver", "Screen saver" },
    .{ "playground", "Swift playground" },
    .{ "pkg", "Installer package" },
    .{ "mpkg", "Installer package" },
    .{ "dSYM", "Debug symbols" },
    .{ "xcarchive", "Xcode archive" },
    .{ "workflow", "Automator workflow" },
    .{ "sparsebundle", "Sparse bundle disk image" },
    .{ "numbers", "Numbers spreadsheet" },
    .{ "pages", "Pages document" },
    .{ "key", "Keynote presentation" },
};

const Kind = struct { []const u8, []const u8 };

const file_kinds = [_]Kind{
    // images
    .{ "jpg", "JPEG image" },           .{ "jpeg", "JPEG image" },
    .{ "png", "PNG image" },            .{ "gif", "GIF image" },
    .{ "tif", "TIFF image" },           .{ "tiff", "TIFF image" },
    .{ "bmp", "Windows bitmap image" }, .{ "heic", "HEIF image" },
    .{ "heif", "HEIF image" },          .{ "webp", "WebP image" },
    .{ "svg", "SVG document" },         .{ "ico", "Windows icon image" },
    .{ "icns", "Apple icon image" },    .{ "psd", "Adobe Photoshop document" },
    .{ "raw", "RAW image" },            .{ "cr2", "Canon RAW image" },
    .{ "nef", "Nikon RAW image" },      .{ "dng", "Adobe Digital Negative image" },
    // documents
    .{ "txt", "Plain text document" },  .{ "text", "Plain text document" },
    .{ "md", "Markdown document" },     .{ "markdown", "Markdown document" },
    .{ "rtf", "Rich Text document" },   .{ "rtfd", "Rich Text with attachments" },
    .{ "pdf", "PDF document" },         .{ "html", "HTML document" },
    .{ "htm", "HTML document" },        .{ "xml", "XML document" },
    .{ "json", "JSON document" },       .{ "yaml", "YAML document" },
    .{ "yml", "YAML document" },        .{ "toml", "TOML document" },
    .{ "csv", "CSV document" },         .{ "tsv", "TSV document" },
    .{ "log", "Log file" },             .{ "plist", "Property list" },
    .{ "doc", "Microsoft Word document" },
    .{ "docx", "Microsoft Word document" },
    .{ "xls", "Microsoft Excel spreadsheet" },
    .{ "xlsx", "Microsoft Excel spreadsheet" },
    .{ "ppt", "Microsoft PowerPoint presentation" },
    .{ "pptx", "Microsoft PowerPoint presentation" },
    .{ "odt", "OpenDocument text document" },
    .{ "ods", "OpenDocument spreadsheet" },
    .{ "epub", "EPUB document" },       .{ "tex", "TeX document" },
    // archives, disk images
    .{ "zip", "Zip archive" },          .{ "tar", "Tar archive" },
    .{ "gz", "GZip archive" },          .{ "tgz", "GZip compressed tar archive" },
    .{ "bz2", "BZip2 archive" },        .{ "xz", "XZ archive" },
    .{ "zst", "Zstandard archive" },    .{ "7z", "7-Zip archive" },
    .{ "rar", "RAR archive" },          .{ "dmg", "Disk Image" },
    .{ "iso", "Disk Image" },
    // audio / video
    .{ "mp3", "MP3 audio" },            .{ "m4a", "MPEG-4 audio" },
    .{ "aac", "AAC audio" },            .{ "wav", "WAVE audio" },
    .{ "aif", "AIFF audio" },           .{ "aiff", "AIFF audio" },
    .{ "flac", "FLAC audio" },          .{ "ogg", "Ogg audio" },
    .{ "mid", "MIDI audio" },           .{ "mp4", "MPEG-4 movie" },
    .{ "m4v", "MPEG-4 movie" },         .{ "mov", "QuickTime movie" },
    .{ "avi", "AVI movie" },            .{ "mkv", "Matroska video" },
    .{ "webm", "WebM movie" },          .{ "mpg", "MPEG movie" },
    .{ "mpeg", "MPEG movie" },
    // source code and scripts
    .{ "swift", "Swift source" },       .{ "zig", "Zig source" },
    .{ "c", "C source" },               .{ "h", "C header" },
    .{ "cc", "C++ source" },            .{ "cpp", "C++ source" },
    .{ "hpp", "C++ header" },           .{ "m", "Objective-C source" },
    .{ "mm", "Objective-C++ source" },  .{ "rs", "Rust source" },
    .{ "go", "Go source" },             .{ "py", "Python script" },
    .{ "rb", "Ruby script" },           .{ "pl", "Perl script" },
    .{ "php", "PHP script" },           .{ "lua", "Lua script" },
    .{ "js", "JavaScript script" },     .{ "mjs", "JavaScript script" },
    .{ "ts", "TypeScript source" },     .{ "tsx", "TypeScript source" },
    .{ "jsx", "JSX source" },           .{ "css", "Cascading Style Sheet" },
    .{ "java", "Java source" },         .{ "kt", "Kotlin source" },
    .{ "sh", "Shell script" },          .{ "zsh", "Shell script" },
    .{ "bash", "Shell script" },        .{ "command", "Shell script" },
    .{ "sql", "SQL document" },         .{ "scpt", "Compiled AppleScript" },
    .{ "applescript", "AppleScript text" },
    // misc
    .{ "ttf", "TrueType font" },        .{ "otf", "OpenType font" },
    .{ "woff", "Web font" },            .{ "woff2", "Web font" },
    .{ "dylib", "Dynamic library" },    .{ "a", "Static library" },
    .{ "o", "Object file" },            .{ "pkg", "Installer package" },
    .{ "torrent", "BitTorrent document" },
    .{ "webloc", "Web internet location" },
    .{ "ics", "Calendar event" },       .{ "vcf", "vCard" },
    .{ "eml", "Email message" },        .{ "key", "Keynote presentation" },
    .{ "numbers", "Numbers spreadsheet" },
    .{ "pages", "Pages document" },
};

/// The extension of `name` without the dot ("" if none). A leading dot alone (".bashrc") is not an extension.
pub fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 >= name.len) return "";
    return name[dot + 1 ..];
}

fn lookup(table: []const Kind, ext: []const u8) ?[]const u8 {
    if (ext.len == 0 or ext.len > 32) return null;
    var buf: [32]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, ext);
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], lower)) return entry[1];
    }
    return null;
}

pub fn isPackageExtension(ext: []const u8) bool {
    if (ext.len == 0) return false;
    for (package_exts) |p| {
        if (std.ascii.eqlIgnoreCase(p, ext)) return true;
    }
    return false;
}

/// Description of a package directory with extension `ext`.
pub fn packageKind(ext: []const u8) []const u8 {
    return lookup(&package_kinds, ext) orelse "Package";
}

/// Table description of a regular file's extension, or null when unknown.
pub fn fileKind(ext: []const u8) ?[]const u8 {
    return lookup(&file_kinds, ext);
}

test "extensionOf" {
    try std.testing.expectEqualStrings("txt", extensionOf("a.txt"));
    try std.testing.expectEqualStrings("gz", extensionOf("a.tar.gz"));
    try std.testing.expectEqualStrings("", extensionOf(".bashrc"));
    try std.testing.expectEqualStrings("", extensionOf("trailing."));
    try std.testing.expectEqualStrings("", extensionOf("noext"));
}

test "kind lookups are case-insensitive" {
    try std.testing.expectEqualStrings("JPEG image", fileKind("JPG").?);
    try std.testing.expectEqualStrings("Plain text document", fileKind("txt").?);
    try std.testing.expect(fileKind("qqqq") == null);
    try std.testing.expect(isPackageExtension("APP"));
    try std.testing.expect(!isPackageExtension("txt"));
    try std.testing.expectEqualStrings("Application", packageKind("app"));
    try std.testing.expectEqualStrings("Package", packageKind("wdgt"));
}
