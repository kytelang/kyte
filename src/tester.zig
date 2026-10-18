//! The `kyte test` runner.
//!
//! This drives the whole test pipeline: it loads the program the user asked to
//! test (a named file, or every `.ky` file under the project), collects the
//! `@test` functions THAT USER wrote, synthesises a `main()` harness that calls
//! each one and tallies pass/fail, then runs the normal compile + link pipeline
//! on the combined program and executes the resulting binary.
//!
//! Two deliberate behaviours are the source of subtle bugs if changed:
//!
//!   1. Only the USER's `@test`s run. The stdlib is merged into the program like
//!      any import and carries its own `@test`s, but re-running those on every
//!      `kyte test` would be noise (they are already covered by the conformance
//!      corpus). [`collectTestFunctions`] filters by source file so stdlib and
//!      package tests are excluded.
//!   2. A file with no `@test` of its own is still COMPILED (it just reports
//!      "0 passed, 0 failed"), so a mistake in such a file is still caught. This
//!      is why the runner falls through to build a trivial harness rather than
//!      returning early when no tests are found.
//!
//! The harness also gates on the ARC leak audit: if `kyte_arc_audit_report`
//! reports survivors the process exits non-zero, so a leak fails the test run.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const ast = @import("frontend/ast.zig");
const lexer = @import("frontend/lexer.zig");
const parser = @import("frontend/parser.zig");
const formatter = @import("frontend/formatter.zig");
const type_checker = @import("frontend/type_checker.zig");
const templates = @import("templates.zig");
const llvm_codegen = @import("backend/codegen/llvm_codegen.zig");
const codegen_arc = @import("backend/codegen/arc.zig");
const sema_shadow = @import("frontend/sema/shadow.zig");
const sema_escape = @import("frontend/sema/escape.zig");
const sema_ownership = @import("frontend/sema/ownership.zig");
const sema_ossa_lower = @import("frontend/sema/ossa/lower.zig");
const sema_alpha = @import("frontend/sema/alpha.zig");
const sema_ids = @import("frontend/sema/ids.zig");
const sema_mod = @import("frontend/sema/sema.zig");
const sema_mono = @import("frontend/sema/mono.zig");
const pipeline = @import("pipeline.zig");
const packages = @import("packages.zig");


/// Collects the names of `@test` functions declared in the USER's files.
///
/// Walks the merged declaration list and keeps a `fn` only when BOTH: its
/// `span.file` (stamped by the parser with the source path) matches one of
/// `user_files`, AND it carries the `@test` attribute. The `span.file` filter is
/// what excludes the stdlib's and imported packages' own tests, which are merged
/// into the program but are not what `kyte test <file>` is asking to run. The
/// returned slice is owned by the caller.
fn collectTestFunctions(declarations: []const ast.Declaration, user_files: []const []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var test_fns = std.ArrayList([]const u8).empty;
    defer test_fns.deinit(allocator);
    for (declarations) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                var from_user_file = false;
                for (user_files) |uf| {
                    if (std.mem.eql(u8, fd.span.file, uf)) {
                        from_user_file = true;
                        break;
                    }
                }
                if (!from_user_file) continue;
                for (fd.attributes) |attr| {
                    switch (attr) {
                        .@"test" => {
                            try test_fns.append(allocator, fd.name);
                            break;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return try test_fns.toOwnedSlice(allocator);
}

/// Generates the Kyte source of the harness `main()` that drives the tests.
///
/// Emits a `main` that, for each test name, resets the per-test state
/// (`kyte_test_reset`), marks the current test (`kyte_test_begin`), calls the
/// test function, and prints `PASS`/`FAIL` based on `kyte_test_did_fail`,
/// accumulating counts. After all tests it prints the `Results:` summary and
/// exits non-zero if the ARC audit reports survivors OR any test failed, so a
/// leak or a failure both fail the process. The result is Kyte source text,
/// parsed and merged into the program alongside the user's code. `console.log`
/// string concatenation is used because the harness is plain Kyte, not Zig.
fn generateTestHarness(test_fn_names: []const []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);

    try src.appendSlice(allocator, "fn main(): void {\n");
    try src.print(allocator, "    let __test_total = {d};\n", .{test_fn_names.len});
    try src.appendSlice(allocator, "    let __test_passed = 0;\n");
    try src.appendSlice(allocator, "    let __test_failed = 0;\n");
    try src.print(allocator, "    console.log(\"Running {d} test(s)...\");\n", .{test_fn_names.len});
    try src.appendSlice(allocator, "    console.log(\"\");\n");

    for (test_fn_names) |name| {
        try src.appendSlice(allocator, "    kyte_test_reset();\n");
        try src.print(allocator, "    kyte_test_begin(\"{s}\");\n", .{name});
        try src.print(allocator, "    {s}();\n", .{name});
        try src.appendSlice(allocator, "    if (kyte_test_did_fail() == 0) {\n");
        try src.print(allocator, "        console.log(\"  PASS  {s}\");\n", .{name});
        try src.appendSlice(allocator, "        __test_passed = __test_passed + 1;\n");
        try src.appendSlice(allocator, "    } else {\n");
        try src.print(allocator, "        console.log(\"  FAIL  {s}\");\n", .{name});
        try src.appendSlice(allocator, "        let msg = kyte_test_fail_message();\n");
        try src.appendSlice(allocator, "        console.log(\"        \" + msg);\n");
        try src.appendSlice(allocator, "        __test_failed = __test_failed + 1;\n");
        try src.appendSlice(allocator, "    }\n");
    }

    try src.appendSlice(allocator, "    console.log(\"\");\n");
    try src.appendSlice(allocator, "    console.log(\"Results: \" + __test_passed + \" passed, \" + __test_failed + \" failed, \" + __test_total + \" total\");\n");

    try src.appendSlice(allocator, "    if (kyte_arc_audit_report() > 0) {\n");
    try src.appendSlice(allocator, "        kyte_exit(1);\n");
    try src.appendSlice(allocator, "    }\n");
    try src.appendSlice(allocator, "    if (__test_failed > 0) {\n");
    try src.appendSlice(allocator, "        kyte_exit(1);\n");
    try src.appendSlice(allocator, "    }\n");
    try src.appendSlice(allocator, "}\n");

    return try src.toOwnedSlice(allocator);
}

/// Entry point for the `kyte test` subcommand.
///
/// Runs the full test pipeline end to end:
///
///   1. Ensures dependencies are fetched, then parses the build-tuning flags
///      (`--split-objects`, `--prune`, `--emit-llvm`, `--mem-stats`, `--wasm`/
///      `--native`, `--asan`/`--tsan`) and the optional target file.
///   2. Determines the files to test: the given file, or every `.ky` file
///      under the current directory when none is named.
///   3. Loads and merges those files (plus `string_builder` and small runtime
///      helpers) into one declaration list, resolving imports transitively.
///   4. Collects the user's `@test`s ([`collectTestFunctions`]), generates the
///      harness ([`generateTestHarness`]), and appends it. `main` from the
///      user's files is dropped so only the harness `main` remains.
///   5. Runs the normal frontend (synthetic generators, alpha-rename, id
///      assignment, type check, TypeId sema, monomorphise, optional
///      reach/escape/ownership/OSSA passes) exactly as a real build does, so a
///      test build exercises the same pipeline as `kyte build`.
///   6. Emits objects, links against the C++ runtime (`kytecore`, or the
///      `_asan`/`_tsan` variant), and runs the produced `__kyte_test` binary.
///
/// The whole `build/test` tree is cleaned up afterwards. The process exits
/// non-zero if the test binary reports failure (which itself covers both a
/// failed assertion and a leak, see [`generateTestHarness`]).
pub fn cmdTest(allocator: std.mem.Allocator, init: std.process.Init, args: []const []const u8) !void {
    try packages.ensureDependencies(allocator, init);

    llvm_codegen.flags.split_per_file = pipeline.hasFlag(args, "--split-objects");
    llvm_codegen.flags.prune = pipeline.hasFlag(args, "--prune");
    llvm_codegen.flags.dump_ir = pipeline.hasFlag(args, "--emit-llvm");
    llvm_codegen.flags.mem_stats = pipeline.hasFlag(args, "--mem-stats");
    // --coverage instruments every user statement with a hit counter; the test
    // binary writes __kyte_cov_data.bin (flat counters) and compilation writes
    // __kyte_cov_metadata.json (id -> file/line/col) next to the cwd.
    const want_coverage = pipeline.hasFlag(args, "--coverage");

    var file_path: []const u8 = "";
    var target: []const u8 = "--native";

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--wasm")) {
            // WASM is no longer a supported target (decision 2026-07-28, finalised 1.0). `kyte build`/`run`
            // already reject it; the test runner must reject it too, otherwise `kyte test --wasm` would
            // still drive the wasm32 LLVM codegen path (is_wasm=true) and leave the dropped target
            // reachable through a side door. Reject here so the user surface is uniformly native-only.
            std.debug.print("WebAssembly is not a supported target. Kyte compiles to native code only.\n", .{});
            return;
        } else if (std.mem.eql(u8, arg, "--native")) {
            target = arg;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // Any other `--flag` (--coverage, --asan, --prune, ...) is consumed by
            // the hasFlag reads above; skip it here so a flag written AFTER the
            // file name does not get mistaken for the file path.
            continue;
        } else {
            file_path = arg;
        }
    }

    var file_paths = std.ArrayList([]const u8).empty;
    defer {
        for (file_paths.items) |p| {
            allocator.free(p);
        }
        file_paths.deinit(allocator);
    }

    if (file_path.len == 0) {
        pipeline.findKyteFiles(allocator, init.io, .cwd(), ".", &file_paths) catch |err| {
            std.debug.print("Failed to scan project directory: {any}\n", .{err});
            return;
        };
        if (file_paths.items.len == 0) {
            std.debug.print("No .ky files found in the current directory.\n", .{});
            return;
        }
    } else {
        const dup = try allocator.dupe(u8, file_path);
        try file_paths.append(allocator, dup);
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var iter = visited.keyIterator();
        while (iter.next()) |k| {
            allocator.free(k.*);
        }
        visited.deinit();
    }
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    var merged = std.ArrayList(u8).empty;
    defer merged.deinit(allocator);

    var file_sources = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iter = file_sources.keyIterator();
        while (iter.next()) |k| {
            allocator.free(k.*);
        }
        file_sources.deinit();
    }

    var declarations = std.ArrayList(ast.Declaration).empty;
    defer declarations.deinit(allocator);

    const is_wasm = std.mem.eql(u8, target, "--wasm");
    const tinfo = pipeline.deriveTargetInfo(target, null);

    pipeline.loadProgram(allocator, init, "src/std/collections/string_builder.ky", &visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
        std.debug.print("Warning: Failed to load string_builder in test harness: {any}\n", .{err});
    };

    for (file_paths.items) |path| {
        pipeline.loadProgram(allocator, init, path, &visited, &visiting, &merged, &declarations, is_wasm, &file_sources, tinfo) catch |err| {
            std.debug.print("Failed to load program {s}: {any}\n", .{ path, err });

            return err;
        };
    }

    const test_fn_names = try collectTestFunctions(declarations.items, file_paths.items, allocator);
    if (test_fn_names.len == 0) {
        if (file_path.len == 0) {
            std.debug.print("No @test functions found in project directory; compiling only.\n", .{});
        } else {
            std.debug.print("No @test functions found in {s}; compiling only.\n", .{file_path});
        }
    } else {
        std.debug.print("Found {d} test function(s)\n", .{test_fn_names.len});
    }

    const harness_src = try generateTestHarness(test_fn_names, allocator);

    var filtered_decls = std.ArrayList(ast.Declaration).empty;
    defer filtered_decls.deinit(allocator);
    for (declarations.items) |decl| {
        switch (decl) {
            .fn_decl => |fd| {
                if (std.mem.eql(u8, fd.name, "main")) continue;
                try filtered_decls.append(allocator, decl);
            },
            else => try filtered_decls.append(allocator, decl),
        }
    }

    var harness_parser = try parser.Parser.init(allocator, harness_src, "test_harness.ky", is_wasm);
    defer harness_parser.deinit();
    const harness_prog = try harness_parser.parseProgram();
    try filtered_decls.appendSlice(allocator, harness_prog.declarations);

    const helpers =
        \\fn __log_i32(val: i32): void {
        \\    console.log(`${val}`);
        \\}
        \\fn __log_bool(val: bool): void {
        \\    if (val) {
        \\        console.log("true");
        \\    } else {
        \\        console.log("false");
        \\    }
        \\}
        \\fn __read_string(ptr: i32, len: i32): string {
        \\    let new_ptr = bytes.alloc(len);
        \\    let i = 0;
        \\    while (i < len) {
        \\        bytes.write_byte(new_ptr, i, bytes.read_byte(ptr, i));
        \\        i = i + 1;
        \\    }
        \\    return new_ptr as string;
        \\}
        \\
    ;
    var helpers_p = try parser.Parser.init(allocator, helpers, "helpers.ky", is_wasm);
    defer helpers_p.deinit();
    const helpers_prog = try helpers_p.parseProgram();
    try filtered_decls.appendSlice(allocator, helpers_prog.declarations);

    try pipeline.expandTraitDefaults(allocator, &filtered_decls);
    try pipeline.generateControllerRoutes(allocator, &filtered_decls);
    // Tests always get the serde `to()`/`from()` sugar (small programs; keeps the
    // serde-format test coverage intact regardless of a given case's `Format.` use).
    try pipeline.generateSerdeBinders(allocator, &filtered_decls, is_wasm, true);
    try pipeline.generateMediatorDispatch(allocator, &filtered_decls, is_wasm);
    try pipeline.generateRuntimeMediator(allocator, &filtered_decls, is_wasm);

    const program = ast.Program{
        .declarations = filtered_decls.items,
        .span = ast.Span{ .start = 0, .end = 0, .line = 1, .col = 1, .file = file_path },
    };

    try sema_alpha.run(allocator, program);

    var id_assigner = sema_ids.Assigner.init();
    try id_assigner.run(program);

    var tc = type_checker.TypeChecker.init(allocator, &file_sources);
    defer tc.deinit();
    try tc.check(program);

    sema_shadow.report_enabled = init.environ_map.get("KYTE_SEMA_SHADOW") != null;
    sema_shadow.tid_census = init.environ_map.get("KYTE_TID_CENSUS") != null;
    codegen_arc.elide_enabled = init.environ_map.get("KYTE_ARC_ELIDE_OFF") == null;
    codegen_arc.arc_census = init.environ_map.get("KYTE_ARC_CENSUS") != null;
    pipeline.configureValueStructs(allocator, init.environ_map);
    sema_shadow.trace_resolution = sema_shadow.report_enabled;
    sema_shadow.f2_types_enabled = true;

    const owned_sema = try sema_mod.Sema.create(allocator);
    defer owned_sema.destroy();
    sema_shadow.run(allocator, program, owned_sema) catch |e| {
        std.debug.print("sema failed: {any}\n", .{e});
    };

    {
        var wl = sema_mono.Worklist.init(allocator, owned_sema);
        defer wl.deinit();
        wl.compute(program) catch |e| std.debug.print("F4 worklist failed: {any}\n", .{e});
        sema_mono.live_instantiations = wl.names(allocator) catch null;
        if (sema_shadow.report_enabled) wl.report();

        if (wl.instIds(allocator) catch null) |ids| {
            defer allocator.free(ids);
            @import("frontend/sema/inst_disp.zig").run(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir, ids);
            @import("frontend/sema/inst_disp.zig").runFreeFns(allocator, &owned_sema.store, &owned_sema.ir, program);
            @import("frontend/sema/inst_disp.zig").runMethods(allocator, &owned_sema.store, &owned_sema.tab, &owned_sema.ir);
        }
    }

    {
        const reach = @import("frontend/sema/reach.zig");
        const shadow = init.environ_map.get("KYTE_REACH_SHADOW") != null;
        const gate = init.environ_map.get("KYTE_REACH_ON") != null;
        if (shadow or gate) {
            var rr = reach.compute(allocator, &owned_sema.tab, &owned_sema.ir, program, true) catch reach.Result{};
            defer rr.deinit(allocator);
            if (shadow) reach.report(&rr, &owned_sema.tab);
            if (gate) {
                reach.publish(allocator, &rr, &owned_sema.tab);
                reach.gate_on = true;
            }
        }
    }

    sema_escape.report_enabled = init.environ_map.get("KYTE_ESCAPE_REPORT") != null;
    if (sema_escape.report_enabled) _ = sema_escape.analyze(allocator, &owned_sema.store, &owned_sema.ir, &program);

    if (init.environ_map.get("KYTE_OWN_VERIFY")) |v| {
        const hard = std.mem.eql(u8, v, "hard");
        sema_ownership.runVerify(allocator, &owned_sema.store, &owned_sema.ir, &program, hard);
        codegen_arc.balance_verify = true;
        codegen_arc.balance_hard = false;
    }

    {
        const ossa = init.environ_map.get("KYTE_OSSA");
        const disabled = ossa != null and std.mem.eql(u8, ossa.?, "off");
        if (!disabled) {
            const report_only = ossa != null and std.mem.eql(u8, ossa.?, "1");
            const verbose = ossa != null;
            const strict = init.environ_map.get("KYTE_OSSA_STRICT") != null;
            sema_ossa_lower.reportQuiet(allocator, &owned_sema.store, &owned_sema.ir, &program, !report_only, !verbose, strict);
        }
    }


    const test_dir = "build/test";
    Io.Dir.createDirPath(.cwd(), init.io, test_dir) catch {};
    const output_path = "build/test/__kyte_test";
    const obj_path = try std.fmt.allocPrint(allocator, "{s}.o", .{output_path});
    defer allocator.free(obj_path);
    const t6_split = llvm_codegen.flags.split_per_file;
    var split_objs = std.ArrayList([]const u8).empty;
    defer {
        for (split_objs.items) |o| {
            Io.Dir.deleteFile(.cwd(), init.io, o) catch {};
            allocator.free(o);
        }
        split_objs.deinit(allocator);
    }
    try llvm_codegen.compile(allocator, program, is_wasm, false, null, obj_path, want_coverage, t6_split, if (t6_split) &split_objs else null, null, init.io);
    const link_objs: []const []const u8 = if (split_objs.items.len > 0) split_objs.items else &[_][]const u8{obj_path};
    sema_shadow.reportDiff();
    sema_shadow.reportTypeIdDiff();
    sema_shadow.tidCensusReport();
    sema_shadow.reportF45();
    sema_mono.dumpMethodInsts();

    const home = init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse "/";
    const shared_kyte = try std.fmt.allocPrint(allocator, "{s}/.kyte", .{ home });
    const shared_kyte_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{shared_kyte});

    const asan = pipeline.hasFlag(args, "--asan");
    const tsan = pipeline.hasFlag(args, "--tsan");

    var test_clang_args = std.ArrayList([]const u8).empty;
    try test_clang_args.append(allocator, pipeline.cxxDriver(asan, init.io));
    try test_clang_args.append(allocator, "-std=c++20");
    try test_clang_args.append(allocator, "-g");
    try test_clang_args.append(allocator, "-O0");
    try test_clang_args.append(allocator, "-pthread");

    try test_clang_args.append(allocator, pipeline.dead_strip_flag);
    try test_clang_args.appendSlice(allocator, pipeline.pie_flags);
    try test_clang_args.append(allocator, "-I.");
    try test_clang_args.append(allocator, shared_kyte_arg);
    if (asan) {
        try test_clang_args.append(allocator, "-fsanitize=address");
        try test_clang_args.append(allocator, "-fno-omit-frame-pointer");
    } else if (tsan) {
        try test_clang_args.append(allocator, "-fsanitize=thread");
        try test_clang_args.append(allocator, "-fno-omit-frame-pointer");
    }

    for (link_objs) |o| try test_clang_args.append(allocator, o);

    try pipeline.appendRuntimeLink(&test_clang_args, allocator, shared_kyte, if (asan)
        "kytecore_asan"
    else if (tsan)
        "kytecore_tsan"
    else
        "kytecore");
    try pipeline.appendWolfsslLink(&test_clang_args, allocator, shared_kyte, init.io);

    for (try pipeline.collectFfiLibs(allocator, program)) |lib| {
        try pipeline.appendFfiLib(&test_clang_args, allocator, shared_kyte, init.io, lib);
    }
    try test_clang_args.append(allocator, "-o");
    try test_clang_args.append(allocator, output_path);

    var child = try std.process.spawn(init.io, .{
        .argv = test_clang_args.items,
    });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("Linking test binary failed with code {d}\n", .{code});
                return error.LinkerFailed;
            }
        },
        else => {
            std.debug.print("Linking test binary failed abnormally\n", .{});
            return error.LinkerFailed;
        },
    }
    Io.Dir.deleteFile(.cwd(), init.io, obj_path) catch {};

    std.debug.print("\n", .{});
    var test_child = try std.process.spawn(init.io, .{
        .argv = &[_][]const u8{"./build/test/__kyte_test"},
    });
    const test_term = try test_child.wait(init.io);

    var suite_failed = false;
    switch (test_term) {
        .exited => |code| {
            if (code != 0) {
                suite_failed = true;
                std.debug.print("\nTest suite FAILED (exit code {d})\n", .{code});
            }
        },
        else => {
            suite_failed = true;
            std.debug.print("\nTest process terminated abnormally\n", .{});
        },
    }

    Io.Dir.deleteTree(.cwd(), init.io, test_dir) catch {};

    // With --coverage, the test binary has just written __kyte_cov_data.bin and
    // compilation wrote __kyte_cov_metadata.json; join them and print a report.
    if (want_coverage) {
        reportCoverage(allocator, init.io) catch |err| {
            std.debug.print("coverage report unavailable: {s}\n", .{@errorName(err)});
        };
    }

    if (suite_failed) std.process.exit(1);
}

/// One metadata record as written by `coverage.zig`'s `writeMetadataFile`.
const CovBlock = struct {
    id: usize,
    file_path: []const u8,
    line: usize,
    col: usize,
    description: []const u8,
};

/// Directory the generated coverage reports are written to, relative to the cwd.
const cov_report_dir = "tests/coverage";

/// Reads the two sidecars that `kyte test --coverage` leaves in the cwd
/// (`__kyte_cov_metadata.json` = id -> file/line/col, `__kyte_cov_data.bin` =
/// flat little-endian i64 hit counts indexed by id) and prints a statement
/// coverage line for each file, then a single total. Project files (relative
/// paths) are listed before imported modules (absolute cache/stdlib paths), and
/// the never-hit lines of each project file are listed so the gaps are actionable.
fn reportCoverage(allocator: std.mem.Allocator, io: std.Io) !void {
    const meta_json = Io.Dir.readFileAlloc(.cwd(), io, "__kyte_cov_metadata.json", allocator, .unlimited) catch
        return error.NoCoverageMetadata;
    defer allocator.free(meta_json);
    const bin = Io.Dir.readFileAlloc(.cwd(), io, "__kyte_cov_data.bin", allocator, .unlimited) catch
        return error.NoCoverageData;
    defer allocator.free(bin);

    const parsed = try std.json.parseFromSlice([]CovBlock, allocator, meta_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const blocks = parsed.value;

    const count = bin.len / @sizeOf(i64);
    const counts = @as([*]const i64, @ptrCast(@alignCast(bin.ptr)))[0..count];

    // Collect the distinct files in first-seen order so output is stable.
    var files = std.ArrayList([]const u8).empty;
    defer files.deinit(allocator);
    for (blocks) |b| {
        var seen = false;
        for (files.items) |f| {
            if (std.mem.eql(u8, f, b.file_path)) {
                seen = true;
                break;
            }
        }
        if (!seen) try files.append(allocator, b.file_path);
    }

    std.debug.print("\n== coverage ==\n", .{});
    var tot_blocks: usize = 0;
    var tot_hit: usize = 0;

    // Two passes so local project files (relative paths) print before imported
    // modules (absolute cache/stdlib paths), without needing to sort in place.
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        const want_local = pass == 0;
        for (files.items) |f| {
            const is_local = f.len == 0 or f[0] != '/';
            if (is_local != want_local) continue;
            var nblk: usize = 0;
            var nhit: usize = 0;
            for (blocks) |b| {
                if (!std.mem.eql(u8, b.file_path, f)) continue;
                nblk += 1;
                if (b.id < count and counts[b.id] > 0) nhit += 1;
            }
            tot_blocks += nblk;
            tot_hit += nhit;
            const pct = if (nblk > 0) nhit * 100 / nblk else 0;
            std.debug.print("  {s}: {d}/{d} statements ({d}%)\n", .{ f, nhit, nblk, pct });
            // List never-hit statements only for genuine project sources: a relative
            // path WITH a directory (for example src/x.ky or tests/y.ky). This skips
            // bare-basename stdlib modules (helpers.ky) and absolute cache paths,
            // whose misses are noise, not the user's gaps.
            const show_misses = is_local and std.mem.indexOfScalar(u8, f, '/') != null;
            if (show_misses) {
                for (blocks) |b| {
                    if (!std.mem.eql(u8, b.file_path, f)) continue;
                    const hits: i64 = if (b.id < count) counts[b.id] else 0;
                    if (hits == 0) {
                        std.debug.print("      MISS line {d} col {d} ({s})\n", .{ b.line, b.col, b.description });
                    }
                }
            }
        }
    }

    const tpct = if (tot_blocks > 0) tot_hit * 100 / tot_blocks else 0;
    std.debug.print("  ----\n", .{});
    std.debug.print("  TOTAL: {d}/{d} statements ({d}%)\n", .{ tot_hit, tot_blocks, tpct });

    // Reports are written under tests/coverage/ so they sit beside the suite and
    // stay out of the project root. The directory is created if absent.
    Io.Dir.createDirPath(.cwd(), io, cov_report_dir) catch {};

    // Also emit a Cobertura XML report for CI and coverage viewers.
    if (writeCobertura(allocator, io, blocks, counts, count, files.items)) {
        std.debug.print("  wrote {s}/coverage.xml (Cobertura)\n", .{cov_report_dir});
    } else |err| {
        std.debug.print("  coverage.xml not written: {s}\n", .{@errorName(err)});
    }

    // And a self-contained HTML report with per-file source and hit/miss highlighting.
    if (writeHtml(allocator, io, blocks, counts, count, files.items)) {
        std.debug.print("  wrote {s}/coverage.html\n", .{cov_report_dir});
    } else |err| {
        std.debug.print("  coverage.html not written: {s}\n", .{@errorName(err)});
    }

    // The sidecars were just rendered; remove them so they do not litter the cwd.
    Io.Dir.deleteFile(.cwd(), io, "__kyte_cov_metadata.json") catch {};
    Io.Dir.deleteFile(.cwd(), io, "__kyte_cov_data.bin") catch {};
}

// Formats `fmt`/`args` and appends the result to `out`. The unmanaged ArrayList
// in this Zig has no `.writer`, so format through a short-lived allocation.
fn fmtInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const tmp = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(tmp);
    try out.appendSlice(allocator, tmp);
}

// Appends `s` to `out` with XML special characters escaped. Filenames and class
// names flow through here so a path with `&` or `<` cannot break the document.
fn xmlAppend(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
}

// Writes the coverage data as a Cobertura XML document (`coverage.xml`). Kyte
// tracks statement hits keyed by (file, line); Cobertura is line-oriented, so a
// line's hit count is the max over the statements on it. Each file becomes a
// <class>, grouped into a <package> by its directory. Branch metrics are reported
// as zero because the instrumentation does not yet distinguish branch arms.
fn writeCobertura(
    allocator: std.mem.Allocator,
    io: std.Io,
    blocks: []const CovBlock,
    counts: []const i64,
    count: usize,
    files: []const []const u8,
) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var tot_lines: usize = 0;
    var tot_hit: usize = 0;
    for (files) |f| {
        var seen_lines = std.ArrayList(usize).empty;
        defer seen_lines.deinit(allocator);
        for (blocks) |b| {
            if (!std.mem.eql(u8, b.file_path, f)) continue;
            var dup = false;
            for (seen_lines.items) |ln| {
                if (ln == b.line) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try seen_lines.append(allocator, b.line);
            tot_lines += 1;
            if (lineHits(blocks, counts, count, f, b.line) > 0) tot_hit += 1;
        }
    }
    const rate: f64 = if (tot_lines > 0) @as(f64, @floatFromInt(tot_hit)) / @as(f64, @floatFromInt(tot_lines)) else 0.0;
    const ts: i64 = 0; // timestamp is informational; left as 0 to avoid a wall-clock dependency

    try out.appendSlice(allocator, "<?xml version=\"1.0\" ?>\n");
    try out.appendSlice(allocator, "<!DOCTYPE coverage SYSTEM \"http://cobertura.sourceforge.net/xml/coverage-04.dtd\">\n");
    try fmtInto(&out, allocator, 
        "<coverage line-rate=\"{d:.4}\" branch-rate=\"0.0\" lines-covered=\"{d}\" lines-valid=\"{d}\" branches-covered=\"0\" branches-valid=\"0\" complexity=\"0\" version=\"kyte\" timestamp=\"{d}\">\n",
        .{ rate, tot_hit, tot_lines, ts },
    );
    try out.appendSlice(allocator, "  <sources><source>.</source></sources>\n");
    try out.appendSlice(allocator, "  <packages>\n");

    // One <package> per file (directory grouping would need dedup; per-file keeps
    // it simple and viewers render it the same). Package name is the directory.
    for (files) |f| {
        var nblk: usize = 0;
        var nhit: usize = 0;
        var seen_lines = std.ArrayList(usize).empty;
        defer seen_lines.deinit(allocator);
        for (blocks) |b| {
            if (!std.mem.eql(u8, b.file_path, f)) continue;
            var dup = false;
            for (seen_lines.items) |ln| {
                if (ln == b.line) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try seen_lines.append(allocator, b.line);
            nblk += 1;
            if (lineHits(blocks, counts, count, f, b.line) > 0) nhit += 1;
        }
        const frate: f64 = if (nblk > 0) @as(f64, @floatFromInt(nhit)) / @as(f64, @floatFromInt(nblk)) else 0.0;
        const dir = std.fs.path.dirname(f) orelse ".";

        try out.appendSlice(allocator, "    <package name=\"");
        try xmlAppend(&out, allocator, dir);
        try fmtInto(&out, allocator, "\" line-rate=\"{d:.4}\" branch-rate=\"0.0\" complexity=\"0\">\n", .{frate});
        try out.appendSlice(allocator, "      <classes>\n");
        try out.appendSlice(allocator, "        <class name=\"");
        try xmlAppend(&out, allocator, std.fs.path.basename(f));
        try out.appendSlice(allocator, "\" filename=\"");
        try xmlAppend(&out, allocator, f);
        try fmtInto(&out, allocator, "\" line-rate=\"{d:.4}\" branch-rate=\"0.0\" complexity=\"0\">\n", .{frate});
        try out.appendSlice(allocator, "          <methods/>\n");
        try out.appendSlice(allocator, "          <lines>\n");

        // Emit one <line> per distinct source line, in the order first seen.
        var emitted = std.ArrayList(usize).empty;
        defer emitted.deinit(allocator);
        for (blocks) |b| {
            if (!std.mem.eql(u8, b.file_path, f)) continue;
            var dup = false;
            for (emitted.items) |ln| {
                if (ln == b.line) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try emitted.append(allocator, b.line);
            const hits = lineHits(blocks, counts, count, f, b.line);
            try fmtInto(&out, allocator, "            <line number=\"{d}\" hits=\"{d}\"/>\n", .{ b.line, hits });
        }

        try out.appendSlice(allocator, "          </lines>\n");
        try out.appendSlice(allocator, "        </class>\n");
        try out.appendSlice(allocator, "      </classes>\n");
        try out.appendSlice(allocator, "    </package>\n");
    }

    try out.appendSlice(allocator, "  </packages>\n");
    try out.appendSlice(allocator, "</coverage>\n");

    try Io.Dir.writeFile(.cwd(), io, .{ .data = out.items, .sub_path = cov_report_dir ++ "/coverage.xml", .flags = .{} });
}

// The hit count for one source line: the maximum over every statement recorded
// on that (file, line), since Cobertura counts a line as covered if any code on
// it ran.
fn lineHits(blocks: []const CovBlock, counts: []const i64, count: usize, file: []const u8, line: usize) i64 {
    var best: i64 = 0;
    for (blocks) |b| {
        if (b.line != line or !std.mem.eql(u8, b.file_path, file)) continue;
        const h: i64 = if (b.id < count) counts[b.id] else 0;
        if (h > best) best = h;
    }
    return best;
}

// Whether any statement at all was recorded on this (file, line) -- i.e. the line
// is instrumented, so it should be coloured hit or miss rather than left neutral.
fn lineInstrumented(blocks: []const CovBlock, file: []const u8, line: usize) bool {
    for (blocks) |b| {
        if (b.line == line and std.mem.eql(u8, b.file_path, file)) return true;
    }
    return false;
}

// Per-file covered/total statement counts (distinct lines with >=1 statement).
const FileStat = struct { nblk: usize, nhit: usize };
fn fileStat(blocks: []const CovBlock, counts: []const i64, count: usize, allocator: std.mem.Allocator, file: []const u8) !FileStat {
    var seen = std.ArrayList(usize).empty;
    defer seen.deinit(allocator);
    var nblk: usize = 0;
    var nhit: usize = 0;
    for (blocks) |b| {
        if (!std.mem.eql(u8, b.file_path, file)) continue;
        var dup = false;
        for (seen.items) |ln| {
            if (ln == b.line) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try seen.append(allocator, b.line);
        nblk += 1;
        if (lineHits(blocks, counts, count, file, b.line) > 0) nhit += 1;
    }
    return .{ .nblk = nblk, .nhit = nhit };
}

// Writes a single self-contained `coverage.html`: an overall summary, a per-file
// table with coverage bars, and, for each project source that can be read, the
// full source with every instrumented line coloured green (hit) or red (missed)
// and its hit count shown in the gutter. No external assets, so it opens offline.
fn writeHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    blocks: []const CovBlock,
    counts: []const i64,
    count: usize,
    files: []const []const u8,
) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var tot_blocks: usize = 0;
    var tot_hit: usize = 0;
    for (files) |f| {
        const s = try fileStat(blocks, counts, count, allocator, f);
        tot_blocks += s.nblk;
        tot_hit += s.nhit;
    }
    const tpct = if (tot_blocks > 0) tot_hit * 100 / tot_blocks else 0;

    try out.appendSlice(allocator,
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>Kyte coverage</title>
        \\<style>
        \\:root{--bg:#0f1115;--panel:#171a21;--fg:#e6e6e6;--muted:#9aa4b2;--line:#262b34;
        \\--hit:#1e7a46;--hitbg:#12261a;--miss:#b4242e;--missbg:#2a1416;--accent:#4aa3ff}
        \\@media (prefers-color-scheme: light){:root{--bg:#f7f8fa;--panel:#fff;--fg:#1c2128;
        \\--muted:#5b6673;--line:#e3e6ea;--hit:#1a7f37;--hitbg:#e6f6ec;--miss:#cf222e;--missbg:#ffebe9;--accent:#0969da}}
        \\*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
        \\font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
        \\.wrap{max-width:1000px;margin:0 auto;padding:32px 20px 80px}
        \\h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin:0 0 24px}
        \\.overall{display:flex;align-items:baseline;gap:12px;margin:0 0 20px}
        \\.big{font-size:40px;font-weight:700}
        \\.bar{height:8px;border-radius:999px;background:var(--line);overflow:hidden}
        \\.bar>span{display:block;height:100%;background:var(--accent)}
        \\table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);
        \\border-radius:10px;overflow:hidden;margin:0 0 32px}
        \\th,td{text-align:left;padding:10px 14px;border-bottom:1px solid var(--line)}
        \\th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
        \\tr:last-child td{border-bottom:none}
        \\td.num{text-align:right;font-variant-numeric:tabular-nums}
        \\td .bar{width:120px;display:inline-block;vertical-align:middle}
        \\a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
        \\.file{background:var(--panel);border:1px solid var(--line);border-radius:10px;margin:0 0 20px;overflow:hidden}
        \\.file h2{font-size:14px;margin:0;padding:12px 14px;border-bottom:1px solid var(--line);
        \\font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
        \\.file h2 .pct{float:right;color:var(--muted);font-family:inherit}
        \\pre{margin:0;overflow-x:auto}
        \\.ln{display:flex;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;white-space:pre}
        \\.ln .g{width:56px;flex:0 0 56px;text-align:right;padding:0 10px;color:var(--muted);
        \\background:rgba(127,127,127,.06);user-select:none;border-right:1px solid var(--line)}
        \\.ln .h{width:44px;flex:0 0 44px;text-align:right;padding:0 8px;color:var(--muted);user-select:none}
        \\.ln .c{padding:0 10px;flex:1}
        \\.ln.hit{background:var(--hitbg)}.ln.hit .h{color:var(--hit);font-weight:600}
        \\.ln.miss{background:var(--missbg)}.ln.miss .h{color:var(--miss);font-weight:700}
        \\</style></head><body><div class="wrap">
        \\<h1>Kyte coverage</h1><p class="sub">Statement coverage. Green lines ran; red lines never did.</p>
        \\
    );

    try fmtInto(&out, allocator,
        "<div class=\"overall\"><div class=\"big\">{d}%</div><div>{d} / {d} statements</div></div>\n", .{ tpct, tot_hit, tot_blocks });
    try fmtInto(&out, allocator, "<div class=\"bar\"><span style=\"width:{d}%\"></span></div>\n", .{tpct});

    // Summary table.
    try out.appendSlice(allocator, "<table><thead><tr><th>File</th><th class=\"num\">Covered</th><th class=\"num\">%</th><th></th></tr></thead><tbody>\n");
    for (files) |f| {
        const s = try fileStat(blocks, counts, count, allocator, f);
        const pct = if (s.nblk > 0) s.nhit * 100 / s.nblk else 0;
        const is_project = (f.len == 0 or f[0] != '/') and std.mem.indexOfScalar(u8, f, '/') != null;
        try out.appendSlice(allocator, "<tr><td>");
        if (is_project) {
            try out.appendSlice(allocator, "<a href=\"#");
            try xmlAppend(&out, allocator, f);
            try out.appendSlice(allocator, "\">");
            try xmlAppend(&out, allocator, f);
            try out.appendSlice(allocator, "</a>");
        } else {
            try xmlAppend(&out, allocator, f);
        }
        try fmtInto(&out, allocator,
            "</td><td class=\"num\">{d}/{d}</td><td class=\"num\">{d}%</td><td><div class=\"bar\"><span style=\"width:{d}%\"></span></div></td></tr>\n",
            .{ s.nhit, s.nblk, pct, pct });
    }
    try out.appendSlice(allocator, "</tbody></table>\n");

    // Per-file source views for readable project sources.
    for (files) |f| {
        const is_project = (f.len == 0 or f[0] != '/') and std.mem.indexOfScalar(u8, f, '/') != null;
        if (!is_project) continue;
        const src = Io.Dir.readFileAlloc(.cwd(), io, f, allocator, .unlimited) catch continue;
        defer allocator.free(src);
        const s = try fileStat(blocks, counts, count, allocator, f);
        const pct = if (s.nblk > 0) s.nhit * 100 / s.nblk else 0;

        try out.appendSlice(allocator, "<div class=\"file\" id=\"");
        try xmlAppend(&out, allocator, f);
        try out.appendSlice(allocator, "\"><h2>");
        try xmlAppend(&out, allocator, f);
        try fmtInto(&out, allocator, "<span class=\"pct\">{d}% ({d}/{d})</span></h2><pre>\n", .{ pct, s.nhit, s.nblk });

        var ln: usize = 1;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |text| : (ln += 1) {
            const instrumented = lineInstrumented(blocks, f, ln);
            const hits = lineHits(blocks, counts, count, f, ln);
            const cls = if (!instrumented) "ln" else if (hits > 0) "ln hit" else "ln miss";
            try out.appendSlice(allocator, "<div class=\"");
            try out.appendSlice(allocator, cls);
            try out.appendSlice(allocator, "\"><span class=\"g\">");
            try fmtInto(&out, allocator, "{d}", .{ln});
            try out.appendSlice(allocator, "</span><span class=\"h\">");
            if (instrumented) {
                try fmtInto(&out, allocator, "{d}&times;", .{hits});
            }
            try out.appendSlice(allocator, "</span><span class=\"c\">");
            try xmlAppend(&out, allocator, text);
            try out.appendSlice(allocator, "</span></div>\n");
        }
        try out.appendSlice(allocator, "</pre></div>\n");
    }

    try out.appendSlice(allocator, "</div></body></html>\n");
    try Io.Dir.writeFile(.cwd(), io, .{ .data = out.items, .sub_path = cov_report_dir ++ "/coverage.html", .flags = .{} });
}
