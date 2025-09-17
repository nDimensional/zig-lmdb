const std = @import("std");
const c = @import("c.zig").c;

pub const Error = error{
    INVAL,
    ACCES,
    NOMEM,
    NOENT,
    AGAIN,
    NOSPC,
    BUSY,
    INTR,
    PIPE,
    IO,

    MDB_KEYEXIST,
    MDB_NOTFOUND,
    MDB_PAGE_NOTFOUND,
    MDB_CORRUPTED,
    MDB_PANIC,
    MDB_VERSION_MISMATCH,
    MDB_INVALID,
    MDB_MAP_FULL,
    MDB_DBS_FULL,
    MDB_READERS_FULL,
    MDB_TLS_FULL,
    MDB_TXN_FULL,
    MDB_CURSOR_FULL,
    MDB_PAGE_FULL,
    MDB_MAP_RESIZED,
    MDB_INCOMPATIBLE,
    MDB_BAD_RSLOT,
    MDB_BAD_TXN,
    MDB_BAD_VALSIZE,
    MDB_BAD_DBI,

    MDB_UNKNOWN_ERROR,
};

pub fn throw(rc: c_int) Error!void {
    try switch (rc) {
        c.MDB_SUCCESS => {},

        // Key/data pair already exists
        c.MDB_KEYEXIST => Error.MDB_KEYEXIST,

        // No matching key/data pair found
        c.MDB_NOTFOUND => Error.MDB_NOTFOUND,

        // Requested page not found
        c.MDB_PAGE_NOTFOUND => Error.MDB_PAGE_NOTFOUND,

        // Located page was wrong type
        c.MDB_CORRUPTED => Error.MDB_CORRUPTED,

        // Update of meta page failed or environment had fatal error
        c.MDB_PANIC => Error.MDB_PANIC,

        // Database environment version mismatch
        c.MDB_VERSION_MISMATCH => Error.MDB_VERSION_MISMATCH,

        // File is not an LMDB file
        c.MDB_INVALID => Error.MDB_INVALID,

        // Environment mapsize limit reached
        c.MDB_MAP_FULL => Error.MDB_MAP_FULL,

        // Environment maxdbs limit reached
        c.MDB_DBS_FULL => Error.MDB_DBS_FULL,

        // Environment maxreaders limit reached
        c.MDB_READERS_FULL => Error.MDB_READERS_FULL,

        // Thread-local storage keys full - too many environments open
        c.MDB_TLS_FULL => Error.MDB_TLS_FULL,

        // Transaction has too many dirty pages - transaction too big
        c.MDB_TXN_FULL => Error.MDB_TXN_FULL,

        // Internal error - cursor stack limit reached
        c.MDB_CURSOR_FULL => Error.MDB_CURSOR_FULL,

        // Internal error - page has no more space
        c.MDB_PAGE_FULL => Error.MDB_PAGE_FULL,

        // Database contents grew beyond environment mapsize
        c.MDB_MAP_RESIZED => Error.MDB_MAP_RESIZED,

        // Operation and DB incompatible, or DB flags changed
        c.MDB_INCOMPATIBLE => Error.MDB_INCOMPATIBLE,

        // Invalid reuse of reader locktable slot
        c.MDB_BAD_RSLOT => Error.MDB_BAD_RSLOT,

        // Transaction must abort, has a child, or is invalid
        c.MDB_BAD_TXN => Error.MDB_BAD_TXN,

        // Unsupported size of key/DB name/data, or wrong DUPFIXED size
        c.MDB_BAD_VALSIZE => Error.MDB_BAD_VALSIZE,

        // The specified DBI handle was closed/changed unexpectedly
        c.MDB_BAD_DBI => Error.MDB_BAD_DBI,

        @intFromEnum(std.posix.E.INVAL) => Error.INVAL,
        @intFromEnum(std.posix.E.ACCES) => Error.ACCES,
        @intFromEnum(std.posix.E.NOMEM) => Error.NOMEM,
        @intFromEnum(std.posix.E.NOENT) => Error.NOENT,
        @intFromEnum(std.posix.E.AGAIN) => Error.AGAIN,
        @intFromEnum(std.posix.E.NOSPC) => Error.NOSPC,
        @intFromEnum(std.posix.E.BUSY) => Error.BUSY,
        @intFromEnum(std.posix.E.INTR) => Error.INTR,
        @intFromEnum(std.posix.E.PIPE) => Error.PIPE,
        @intFromEnum(std.posix.E.IO) => Error.IO,

        else => Error.MDB_UNKNOWN_ERROR,
    };
}
