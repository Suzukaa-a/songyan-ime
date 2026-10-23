import CryptoKit
import XCTest

@testable import PackageManager

final class LuaSandboxTests: XCTestCase {
    func testWrapIsIdempotentAndByteExact() throws {
        let originals: [Data?] = [
            nil, Data(), Data("rime_x = 1\n".utf8), Data("s = [[a]] t = [=[b]=] u = \"]=\"\n]=".utf8),
            Data([0x2D, 0x2D, 0xFF, 0xFE, 0x0D, 0x0A]),
        ]
        for original in originals {
            let wrapped = LuaSandbox.wrap(original)
            XCTAssertEqual(LuaSandbox.wrap(wrapped), wrapped)
            switch LuaSandbox.unwrap(wrapped) {
            case .some(let value): XCTAssertEqual(value, original)
            case .none: XCTFail("generated entry not recognised")
            }
            XCTAssertEqual(LuaSandbox.restoreOriginal(wrapped), original)
        }
        let plain = Data("print('x')\n".utf8)
        XCTAssertTrue(LuaSandbox.unwrap(plain) == nil)
        XCTAssertEqual(LuaSandbox.restoreOriginal(plain), plain)
        XCTAssertTrue(LuaSandbox.requiresSandbox(paths: ["a.schema.yaml", "lua/x.lua"]))
        XCTAssertTrue(LuaSandbox.requiresSandbox(paths: ["rime.lua"]))
        XCTAssertFalse(LuaSandbox.requiresSandbox(paths: ["a.schema.yaml", "lua/readme.md"]))
    }

    func testMultipleClosingDelimitersChooseFirstUnusedLevel() {
        // Adjacent delimiters share their closing/opening "]" byte.
        assertSafeDelimiter(Data("]=]==]====]".utf8), level: 3)
        var source = Data()
        for level in 1...1024 {
            source += Data(("]" + String(repeating: "=", count: level) + "]").utf8)
        }
        assertSafeDelimiter(source, level: 1025)
    }

    func testPartialClosingDelimiterAtSourceBoundaryIsExcluded() {
        let cases: [(String, Int)] = [
            ("]=", 2),
            ("]=]]=", 2),
            ("]=]]=]==", 3),
            ("]=]==]===", 4),
            // Only a partial run matching the chosen level can cross the boundary.
            ("]==", 1),
            ("]", 1),
            ("===", 1),
            ("]=\n", 1),
        ]
        for (source, level) in cases {
            assertSafeDelimiter(Data(source.utf8), level: level)
        }
        // Delimiter selection is byte-based, including non-UTF8 source and slices.
        let bytes = Data([0x00, 0xFF, 0xFE, 0x5D, 0x3D])
        assertSafeDelimiter(bytes.dropFirst(), level: 2)
    }

    private func assertSafeDelimiter(_ source: Data, level: Int, file: StaticString = #filePath, line: UInt = #line) {
        let wrapped = LuaSandbox.wrap(source)
        let equals = String(repeating: "=", count: level)
        let prefix = Data(
            (LuaSandbox.header + LuaSandbox.prelude + "local __keyboard_sandbox_source = [" + equals + "[\n").utf8)
        let close = Data(("]" + equals + "]").utf8)
        XCTAssertTrue(wrapped.starts(with: prefix), "expected delimiter level \(level)", file: file, line: line)
        // Checking unwrap alone misses premature Lua string termination. Search the
        // actual embedded body plus its appended close, as Lua's lexer would do.
        let bodyAndClose = wrapped.dropFirst(prefix.count)
        XCTAssertEqual(bodyAndClose.range(of: close)?.lowerBound, prefix.count + source.count, file: file, line: line)
        XCTAssertEqual(LuaSandbox.restoreOriginal(wrapped), source, file: file, line: line)
        XCTAssertEqual(LuaSandbox.wrap(wrapped), wrapped, file: file, line: line)
    }

    /// Executes the generated entry with a host Lua 5.4 the way librime-lua's lua_init does.
    func testPreludeRestrictsIOAndKeepsPackageScriptsWorking() throws {
        let lua = ["/opt/homebrew/bin/lua5.4", "/opt/homebrew/bin/lua", "/usr/local/bin/lua5.4", "/usr/local/bin/lua"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let lua else { throw XCTSkip("host Lua 5.4 not installed") }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lua-sandbox-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let shared = base.appendingPathComponent("shared"), user = base.appendingPathComponent("user")
        let outside = base.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("lua"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("secret\n".utf8).write(to: outside)
        try Data("return 'outside module secret'\n".utf8).write(to: base.appendingPathComponent("outside.lua"))
        try Data("hello\n".utf8).write(to: shared.appendingPathComponent("lua/data.txt"))
        try Data(
            """
            local M = {}
            function M.read()
              local f = io.open(rime_api.get_shared_data_dir() .. "/lua/data.txt", "r")
              local line = f:read("l"); f:close(); return line
            end
            return M
            """.utf8
        ).write(to: shared.appendingPathComponent("lua/helper.lua"))
        try FileManager.default.createDirectory(
            at: shared.appendingPathComponent("lua/directory"), withIntermediateDirectories: true)
        try Data("return require('helper')\n".utf8).write(to: shared.appendingPathComponent("lua/directory/init.lua"))
        try Data("return require('directory')\n".utf8).write(to: shared.appendingPathComponent("lua/chain.lua"))
        let packageRime = Data(
            "local helper = require('chain')\nfunction package_translator() return helper.read() end\n".utf8)
        try LuaSandbox.wrap(packageRime).write(to: shared.appendingPathComponent("rime.lua"))
        try LuaSandbox.wrap(Data("this is not lua (\n".utf8)).write(to: base.appendingPathComponent("broken.lua"))
        let runner = base.appendingPathComponent("runner.lua")
        try Data(
            """
            local shared, user, outside, broken = ...
            rime_api = { get_shared_data_dir = function() return shared end, get_user_data_dir = function() return user end }
            package.path = user .. "/lua/?.lua;" .. shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path
            local raw_open = io.open
            local binary = assert(raw_open(shared .. "/lua/binary.lua", "wb"))
            binary:write(string.dump(function() return "binary executed" end)); binary:close()
            local function check(cond, label) if not cond then print("FAIL " .. label); error(label) end end
            -- A broken package script must still leave the prelude installed.
            check(not pcall(dofile, broken), "broken script reports error")
            check(io.open ~= raw_open, "prelude applied before broken script")
            dofile(shared .. "/rime.lua")
            check(package_translator() == "hello", "package global + require + read inside data dir")
            check(io.open(outside, "r") == nil, "read outside roots denied")
            check(io.open(shared .. "/lua/../../outside.txt", "r") == nil, "dotdot denied")
            check(io.open(shared .. "/lua/new.txt", "w") == nil, "write denied")
            check(io.open(user .. "/rime.lua", "a") == nil, "append denied")
            check(not pcall(io.lines, outside), "io.lines outside denied")
            check(not pcall(io.output, user .. "/x"), "io.output path denied")
            check(io.popen("ls") == nil, "popen denied")
            check(io.tmpfile() == nil, "tmpfile denied")
            check(os.remove(outside) == nil and raw_open(outside, "r") ~= nil, "os.remove denied")
            check(os.rename(outside, outside .. ".x") == nil, "os.rename denied")
            check(os.getenv("HOME") == nil, "getenv hidden")
            check(not pcall(os.exit), "os.exit denied")
            check(not pcall(os.tmpname), "tmpname denied")
            check(package.cpath == "" and #package.searchers == 2, "C loaders removed")
            check(package.loadlib("x", "y") == nil, "loadlib denied")
            check(debug.getupvalue == nil and require("debug").getupvalue == nil, "debug upvalue access removed")
            check(load(string.dump(function() end)) == nil, "binary chunks refused")
            check(loadfile(outside) == nil, "loadfile outside denied")
            local allowed_path = package.path
            package.path = shared .. "/../?.lua"
            check(not pcall(require, "outside"), "require outside roots denied")
            check(type(package.searchers[2]("outside")) ~= "function", "direct Lua searcher outside denied")
            package.path = allowed_path
            check(not pcall(require, "binary"), "require binary chunks refused")
            check(not pcall(package.searchers[2], "binary"), "direct Lua searcher binary refused")
            check(type(os.time()) == "number" and type(os.date("%Y")) == "string", "time APIs kept")
            print("OK")
            """.utf8
        ).write(to: runner)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lua)
        process.arguments = [
            runner.path, shared.path, user.path, outside.path, base.appendingPathComponent("broken.lua").path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("OK"), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testInstallWritesSandboxEntryAndReadBackRestoresOriginal() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lua-install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let packageRime = Data("function t() end\n".utf8)
        for (index, includeRime) in [true, false].enumerated() {
            var bytes = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8), "lua/x.lua": Data("return {}\n".utf8)]
            if includeRime { bytes["rime.lua"] = packageRime }
            let manifest = RecipeManifest(
                id: "test", repository: "user/test", revision: String(repeating: "a", count: 40),
                recipePath: "a.schema.yaml", license: "test", schemaID: "a", requiredComponents: [],
                files: bytes.map {
                    .init(
                        path: $0.key, sha256: SHA256.hash(data: $0.value).map { String(format: "%02x", $0) }.joined(),
                        size: $0.value.count)
                },
                origin: .userScheme)
            let manager = RecipePackageManager(rootURL: base.appendingPathComponent("store\(index)"))
            let packageFiles = bytes
            _ = try await manager.installResources(
                manifest, initialUserDataURL: nil,
                deploy: { d in
                    let entry = try Data(contentsOf: d.resourceURL.appendingPathComponent("rime.lua"))
                    XCTAssertEqual(LuaSandbox.restoreOriginal(entry), includeRime ? packageRime : nil)
                    XCTAssertTrue(LuaSandbox.unwrap(entry) != nil)
                    let build = d.userDataURL.appendingPathComponent("build")
                    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
                    try Data("schema_list: [{schema: a}]".utf8).write(to: build.appendingPathComponent("default.yaml"))
                    try Data("schema: {schema_id: a}".utf8).write(to: build.appendingPathComponent("a.schema.yaml"))
                    return .init(availableComponents: [], validatedSchemaID: "a", validatedEnabledSchemaIDs: ["a"])
                }, read: { packageFiles[$0.path]! })
            let active = try await manager.activeInstallation()!
            let snapshot = try RecipePackageManager.readRecipeWorkspaceSnapshot(resources: active.resourceURL)
            XCTAssertEqual(snapshot.files["rime.lua"], includeRime ? packageRime : nil)
            XCTAssertEqual(snapshot.files["lua/x.lua"], bytes["lua/x.lua"])
        }
    }
}
