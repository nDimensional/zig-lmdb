# zig-lmdb

Zig bindings for LMDB.

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)
- [API](#api)
  - [`Environment`](#environment)
  - [`Transaction`](#transaction)
  - [`Database`](#database)
  - [`Cursor`](#cursor)
  - [`Stat`](#stat)

## Installation

The most recent tagged release is built and tested with Zig version `0.16.0`.

```
zig fetch --save=lmdb \
  https://github.com/nDimensional/zig-lmdb/archive/refs/tags/v0.4.0+0.9.35.tar.gz
```

The `main` branch roughly tracks Zig nightly, which you can install via specific commit.

```
zig fetch --save=lmdb \
  https://github.com/nDimensional/zig-lmdb/archive/${COMMIT_HASH}.tar.gz
```

## Usage

An LMDB environment can either have multiple named databases, or a single unnamed database.

To use a single unnamed database, open a transaction and use the `txn.get`, `txn.set`, `txn.delete`, and `txn.cursor` methods directly.

```zig
const lmdb = @import("lmdb");

pub fn main() !void {
    const env = try lmdb.Environment.init("path/to/db", .{});
    defer env.deinit();

    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    errdefer txn.abort();

    try txn.set("aaa", "foo");
    try txn.set("bbb", "bar");

    try txn.commit();
}
```

To use named databases, open the environment with a non-zero `max_dbs` value. Then open each named database using `Transaction.database`, which returns a `Database` struct with `db.get`/`db.set`/`db.delete`/`db.cursor` methods. You don't have to close databases, but they're only valid during the lifetime of the transaction.

```zig
const lmdb = @import("lmdb");

pub fn main() !void {
    const env = try lmdb.Environment.init("path/to/db", .{ .max_dbs = 2 });
    defer env.deinit();

    const txn = try lmdb.Transaction.init(env, .{ .mode = .ReadWrite });
    errdefer txn.abort();

    const widgets = try txn.database("widgets", .{ .create = true });
    try widgets.set("aaa", "foo");

    const gadgets = try txn.database("gadgets", .{ .create = true });
    try gadgets.set("aaa", "bar");

    try txn.commit();
}
```

## API

### `Environment`

```zig
pub const Environment = struct {
    pub const Options = struct {
        map_size: usize = 10 * 1024 * 1024,
        max_dbs: u32 = 0,
        max_readers: u32 = 126,
        read_only: bool = false,
        write_map: bool = false,
        no_tls: bool = false,
        no_lock: bool = false,
        mode: u16 = 0o664,
    };

    pub const Info = struct {
        map_size: usize,
        max_readers: u32,
        num_readers: u32,
    };

    pub fn init(path: [*:0]const u8, options: Options) !Environment
    pub fn deinit(self: Environment) void

    pub fn transaction(self: Environment, options: Transaction.Options) !Transaction

    pub fn sync(self: Environment) !void
    pub fn info(self: Environment) !Info
    pub fn stat(self: Environment) !Stat

    pub fn resize(self: Environment, size: usize) !void // mdb_env_set_mapsize
};
```

### `Transaction`

```zig
pub const Transaction = struct {
    pub const Mode = enum { ReadOnly, ReadWrite };

    pub const Options = struct {
        mode: Mode,
        parent: ?Transaction = null,
    };

    pub fn init(env: Environment, options: Options) !Transaction
    pub fn abort(self: Transaction) void
    pub fn commit(self: Transaction) !void

    pub fn get(self: Transaction, key: []const u8) !?[]const u8
    pub fn set(self: Transaction, key: []const u8, value: []const u8) !void
    pub fn delete(self: Transaction, key: []const u8) !void

    pub fn cursor(self: Database) !Cursor
    pub fn database(self: Transaction, name: ?[*:0]const u8, options: Database.Options) !Database
};
```

### `Database`

```zig
pub const Database = struct {
    pub const Options = struct {
        reverse_key: bool = false,
        integer_key: bool = false,
        create: bool = false,
    };

    pub fn open(txn: Transaction, name: ?[*:0]const u8, options: Options) !Database

    pub fn get(self: Database, key: []const u8) !?[]const u8
    pub fn set(self: Database, key: []const u8, value: []const u8) !void
    pub fn delete(self: Database, key: []const u8) !void

    pub fn cursor(self: Database) !Cursor

    pub fn stat(self: Database) !Stat
};
```

### `Cursor`

```zig
pub const Cursor = struct {
    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn init(db: Database) !Cursor
    pub fn deinit(self: Cursor) void

    pub fn getCurrentEntry(self: Cursor) !Entry
    pub fn getCurrentKey(self: Cursor) ![]const u8
    pub fn getCurrentValue(self: Cursor) ![]const u8

    pub fn setCurrentValue(self: Cursor, value: []const u8) !void
    pub fn deleteCurrentKey(self: Cursor) !void

    pub fn goToNext(self: Cursor) !?[]const u8
    pub fn goToPrevious(self: Cursor) !?[]const u8
    pub fn goToLast(self: Cursor) !?[]const u8
    pub fn goToFirst(self: Cursor) !?[]const u8
    pub fn goToKey(self: Cursor, key: []const u8) !void

    pub fn seek(self: Cursor, key: []const u8) !?[]const u8
};
```

> ⚠️ Always close cursors **before** committing or aborting the transaction.

### `Stat`

```zig
pub const Stat = struct {
    psize: u32,
    depth: u32,
    branch_pages: usize,
    leaf_pages: usize,
    overflow_pages: usize,
    entries: usize,
};
```
