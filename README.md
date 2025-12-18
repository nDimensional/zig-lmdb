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
- [Benchmarks](#benchmarks)

## Installation

The most recent tagged release is built and tested with Zig version `0.15.1`.

```
zig fetch --save=lmdb \
  https://github.com/nDimensional/zig-lmdb/archive/refs/tags/v0.3.2.tar.gz
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

## Benchmarks

```
zig build bench
```

## Benchmarks

As recorded on an M3 MacBook Air:

### 1k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std | ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | ------: |
| get random 1 entry       |        100 |   0.0011 |   0.0315 |   0.0017 | 0.0030 |  599992 |
| get random 100 entries   |        100 |   0.0545 |   0.1025 |   0.0905 | 0.0171 | 1104825 |
| iterate over all entries |        100 |   0.1564 |   0.2440 |   0.1772 | 0.0134 | 5642318 |
| set random 1 entry       |        100 |   0.0623 |   0.1711 |   0.0729 | 0.0182 |   13713 |
| set random 100 entries   |        100 |   0.2892 |   0.3872 |   0.3133 | 0.0181 |  319201 |
| set random 1k entries    |         10 |   2.2540 |   2.3905 |   2.3181 | 0.0485 |  431394 |
| set random 50k entries   |         10 | 110.6715 | 113.6053 | 112.5423 | 0.8446 |  444277 |

### 50k entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std | ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | ------: |
| get random 1 entry       |        100 |   0.0008 |   0.0270 |   0.0023 | 0.0026 |  435485 |
| get random 100 entries   |        100 |   0.0679 |   0.1227 |   0.0746 | 0.0077 | 1339883 |
| iterate over all entries |        100 |   5.6932 |   6.2481 |   5.9927 | 0.0832 | 8343507 |
| set random 1 entry       |        100 |   0.0566 |   0.5343 |   0.0790 | 0.0574 |   12657 |
| set random 100 entries   |        100 |   0.6045 |   0.9053 |   0.6917 | 0.0671 |  144577 |
| set random 1k entries    |         10 |   2.9933 |   3.1644 |   3.0686 | 0.0447 |  325886 |
| set random 50k entries   |         10 | 128.3916 | 131.6171 | 129.9763 | 0.9721 |  384686 |

### 1m entries

|                          | iterations | min (ms) | max (ms) | avg (ms) |    std | ops / s |
| :----------------------- | ---------: | -------: | -------: | -------: | -----: | ------: |
| get random 1 entry       |        100 |   0.0012 |   0.0208 |   0.0027 | 0.0018 |  367193 |
| get random 100 entries   |        100 |   0.1050 |   0.2115 |   0.1282 | 0.0217 |  779952 |
| iterate over all entries |        100 | 120.6643 | 124.6468 | 122.2648 | 0.7610 | 8178966 |
| set random 1 entry       |        100 |   0.0670 |   0.4119 |   0.0890 | 0.0412 |   11232 |
| set random 100 entries   |        100 |   1.0046 |   2.4578 |   2.0798 | 0.1833 |   48082 |
| set random 1k entries    |         10 |   9.9543 |  14.9900 |  13.3877 | 1.7281 |   74696 |
| set random 50k entries   |         10 | 177.7694 | 182.2383 | 180.3549 | 1.4246 |  277231 |
