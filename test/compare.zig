const std = @import("std");

const lmdb = @import("lmdb");

const Options = struct {
    log: ?*std.io.Writer = null,
};

pub fn compareEnvironments(env_a: lmdb.Environment, env_b: lmdb.Environment, dbs: ?[][*:0]const u8, options: Options) !usize {
    const txn_a = try lmdb.Transaction.init(env_a, .{ .mode = .ReadOnly });
    defer txn_a.abort();

    const txn_b = try lmdb.Transaction.init(env_b, .{ .mode = .ReadOnly });
    defer txn_b.abort();

    if (dbs) |names| {
        var sum: usize = 0;
        for (names) |name| {
            const db_a = try txn_a.database(name, .{});
            const db_b = try txn_b.database(name, .{});
            sum += try compareDatabases(db_a, db_b, options);
        }

        return sum;
    } else {
        const db_a = try txn_a.database(null, .{});
        const db_b = try txn_b.database(null, .{});
        return try compareDatabases(db_a, db_b, options);
    }
}

pub fn compareDatabases(db_a: lmdb.Database, db_b: lmdb.Database, options: Options) !usize {
    if (options.log) |log|
        try log.print("{s:-<80}\n", .{"START DIFF "});

    var differences: usize = 0;

    const cursor_a = try lmdb.Cursor.init(db_a);
    defer cursor_a.deinit();

    const cursor_b = try lmdb.Cursor.init(db_b);
    defer cursor_b.deinit();

    var key_a = try cursor_a.goToFirst();
    var key_b = try cursor_b.goToFirst();
    while (key_a != null or key_b != null) {
        if (key_a) |key_a_bytes| {
            const value_a = try cursor_a.getCurrentValue();
            if (key_b) |key_b_bytes| {
                const value_b = try cursor_b.getCurrentValue();
                switch (std.mem.order(u8, key_a_bytes, key_b_bytes)) {
                    .lt => {
                        differences += 1;
                        if (options.log) |log|
                            try log.print("{x}\n- a: {x}\n- b: null\n", .{ key_a_bytes, value_a });

                        key_a = try cursor_a.goToNext();
                    },
                    .gt => {
                        differences += 1;
                        if (options.log) |log|
                            try log.print("{x}\n- a: null\n- b: {x}\n", .{ key_b_bytes, value_b });

                        key_b = try cursor_b.goToNext();
                    },
                    .eq => {
                        if (!std.mem.eql(u8, value_a, value_b)) {
                            differences += 1;
                            if (options.log) |log|
                                try log.print("{x}\n- a: {x}\n- b: {x}\n", .{ key_a_bytes, value_a, value_b });
                        }

                        key_a = try cursor_a.goToNext();
                        key_b = try cursor_b.goToNext();
                    },
                }
            } else {
                differences += 1;
                if (options.log) |log|
                    try log.print("{x}\n- a: {x}\n- b: null\n", .{ key_a_bytes, value_a });

                key_a = try cursor_a.goToNext();
            }
        } else {
            if (key_b) |bytes_b| {
                const value_b = try cursor_b.getCurrentValue();
                differences += 1;
                if (options.log) |log|
                    try log.print("{x}\n- a: null\n- b: {x}\n", .{ bytes_b, value_b });

                key_b = try cursor_b.goToNext();
            } else {
                break;
            }
        }
    }

    if (options.log) |log|
        try log.print("{s:-<80}\n", .{"END DIFF "});

    return differences;
}
