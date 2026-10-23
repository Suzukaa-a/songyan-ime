import Foundation

/// Runtime Lua sandbox for imported schemes.
///
/// The vendored librime-lua engine opens the full Lua standard library (only
/// `os.execute`'s shell is stubbed at build time). librime-lua's `lua_init`
/// runs `<user_data_dir>/rime.lua`, else `<shared_data_dir>/rime.lua`, once,
/// before any `lua_*@` component module is required. The keyboard's
/// shared_data_dir is the published `resources/` directory written by
/// `RecipePackageManager.installResources`; the user data directories are
/// app-private learning stores that never receive Lua files.
///
/// Every installed generation that carries Lua therefore gets a generated
/// `resources/rime.lua`: this prelude first, then the package's own `rime.lua`
/// (embedded as a long string and loaded in text mode, so a syntax error in
/// the package script cannot skip the prelude). `restoreOriginal` returns the original
/// bytes for workspace read-back, keeping the transformation idempotent.
public enum LuaSandbox {
    static let header = "-- >>> Songyan keyboard Lua sandbox v1 (generated at install; edits are discarded) >>>\n"
    static let trailer = "-- <<< Songyan keyboard Lua sandbox v1 <<<\n"
    private static let sourceIntro = "local __keyboard_sandbox_source = "
    private static let absentSource = "nil\n"

    /// Only `rime.lua` at the package root is executed by librime-lua.
    public static let entryPath = "rime.lua"

    /// Whether a resource set can execute Lua and must carry the sandbox entry.
    public static func requiresSandbox<S: Sequence>(paths: S) -> Bool where S.Element == String {
        paths.contains { $0 == entryPath || ($0.hasPrefix("lua/") && $0.hasSuffix(".lua")) }
    }

    /// Prelude + original. Already generated input is unwrapped first (idempotent).
    public static func wrap(_ original: Data?) -> Data {
        var source = original
        if let original, let unwrapped = unwrap(original) { source = unwrapped }
        return render(source)
    }

    private static func render(_ source: Data?) -> Data {
        var output = Data((header + prelude + sourceIntro).utf8)
        if let source {
            // Record complete closing brackets in one byte scan. A closing "]" can
            // also start the next bracket, so retain it as a new zero-length run.
            var forbiddenLevels = Set<Int>()
            var equalsRun: Int?
            for byte in source {
                if byte == UInt8(ascii: "]") {
                    if let equalsRun, equalsRun > 0 { forbiddenLevels.insert(equalsRun) }
                    equalsRun = 0
                } else if byte == UInt8(ascii: "="), let count = equalsRun {
                    equalsRun = count + 1
                } else {
                    equalsRun = nil
                }
            }
            // A trailing "]=..." would consume the first "]" of the appended
            // delimiter and close the Lua string early at that same level.
            if let equalsRun, equalsRun > 0 { forbiddenLevels.insert(equalsRun) }
            var level = 1
            while forbiddenLevels.contains(level) { level += 1 }
            let equals = String(repeating: "=", count: level)
            // Lua skips the first newline right after the opening long bracket.
            output += Data(("[" + equals + "[\n").utf8)
            output += source
            output += Data(("]" + equals + "]\n").utf8)
        } else {
            output += Data(absentSource.utf8)
        }
        output += Data((loader + trailer).utf8)
        return output
    }

    /// nil: `data` is not a generated entry. `.some(nil)`: generated entry
    /// without a package script. `.some(bytes)`: the package's original rime.lua.
    /// Byte-exact (no String/grapheme normalization).
    public static func unwrap(_ data: Data) -> Data?? {
        let bytes = [UInt8](data)
        let head = [UInt8]((header + prelude + sourceIntro).utf8)
        let tail = [UInt8]((loader + trailer).utf8)
        guard bytes.starts(with: head),
            bytes.count >= head.count + tail.count,
            Array(bytes.suffix(tail.count)) == tail
        else { return nil }
        let middle = Array(bytes[head.count..<(bytes.count - tail.count)])
        if middle == [UInt8](absentSource.utf8) { return .some(nil) }
        var level = 0
        while level + 1 < middle.count, middle[level + 1] == UInt8(ascii: "=") { level += 1 }
        let equals = [UInt8](repeating: UInt8(ascii: "="), count: level)
        let open = [UInt8(ascii: "[")] + equals + [UInt8(ascii: "["), 0x0A]
        let close = [UInt8(ascii: "]")] + equals + [UInt8(ascii: "]"), 0x0A]
        guard level > 0, middle.count >= open.count + close.count, middle.starts(with: open),
            Array(middle.suffix(close.count)) == close
        else { return nil }
        return .some(Data(middle[open.count..<(middle.count - close.count)]))
    }

    /// Bytes to expose to workspace read-back: the package's own rime.lua, nil
    /// when the entry was generated without one (the file should be treated as
    /// absent), or `data` unchanged when it is not a generated entry.
    public static func restoreOriginal(_ data: Data) -> Data? {
        guard let unwrapped = unwrap(data) else { return data }
        return unwrapped
    }

    static let prelude = basePrelude.replacingOccurrences(
        of: "  load = function(chunk, name, mode, ...)\n",
        with: moduleSearcher + "  load = function(chunk, name, mode, ...)\n")

    private static let moduleSearcher = #"""
          -- The native Lua searcher bypasses the global loadfile wrapper and accepts
          -- bytecode. Replace it rather than wrapping require: callers can invoke a
          -- searcher directly, and package.path remains writable by package scripts.
          local sgmatch = string.gmatch
          if type(searchers) == "table" then
            searchers[2] = function(name)
              if type(name) ~= "string" then error("module name must be a string", 2) end
              local module = sgsub(name, "%.", "/")
              if type(package.path) ~= "string" then error("package.path must be a string", 2) end
              for pattern in sgmatch(package.path, "[^;]+") do
                local path = sgsub(pattern, "%?", function() return module end)
                if permitted(path) then
                  local file = raw_open(path, "rb")
                  if file then
                    file:close()
                    local chunk, message = raw_loadfile(path, "t")
                    if not chunk then error(message, 0) end
                    return chunk, path
                  end
                end
              end
              return "\n\tno permitted Lua source for '" .. name .. "'"
            end
          end

        """#

    private static let basePrelude = #"""
        do
          local type, error, pcall, select, tostring = type, error, pcall, select, tostring
          local sfind, ssub, sgsub, sbyte = string.find, string.sub, string.gsub, string.byte
          local raw_open, raw_lines, raw_input, raw_output = io.open, io.lines, io.input, io.output
          local raw_load, raw_loadfile = load, loadfile
          local denied = "not permitted by keyboard sandbox"
          local roots = {}
          local function add_root(getter)
            if type(rime_api) ~= "table" or type(rime_api[getter]) ~= "function" then return end
            local ok, dir = pcall(rime_api[getter])
            if ok and type(dir) == "string" and sbyte(dir, 1) == 47 then
              dir = sgsub(dir, "/+$", "")
              if dir ~= "" and not sfind("/" .. dir .. "/", "/../", 1, true) then roots[#roots + 1] = dir .. "/" end
            end
          end
          add_root("get_shared_data_dir")
          add_root("get_user_data_dir")
          local function permitted(path)
            if type(path) ~= "string" or sfind(path, "\0", 1, true) then return false end
            if sfind("/" .. path .. "/", "/../", 1, true) then return false end
            for i = 1, #roots do
              local root = roots[i]
              if ssub(path, 1, #root) == root then return true end
            end
            return false
          end
          local function refuse(what) return nil, tostring(what) .. ": " .. denied, 13 end
          local function raise(what) error(tostring(what) .. ": " .. denied, 3) end

          io.open = function(path, mode)
            if mode == nil then mode = "r" end
            if (mode == "r" or mode == "rb") and permitted(path) then return raw_open(path, mode) end
            return refuse(path)
          end
          io.lines = function(path, ...)
            if path == nil then return raw_lines() end
            if not permitted(path) then raise(path) end
            return raw_lines(path, ...)
          end
          io.input = function(file)
            if file ~= nil and type(file) ~= "userdata" and not permitted(file) then raise(file) end
            return raw_input(file)
          end
          io.output = function(file)
            if file ~= nil and type(file) ~= "userdata" then raise(file) end
            return raw_output(file)
          end
          io.popen = function(command) return refuse("io.popen") end
          io.tmpfile = function() return refuse("io.tmpfile") end

          os.execute = function(command) if command == nil then return false end return refuse("os.execute") end
          os.remove = function(path) return refuse(path) end
          os.rename = function(path) return refuse(path) end
          os.tmpname = function() raise("os.tmpname") end
          os.getenv = function() return nil end
          os.exit = function() raise("os.exit") end

          package.loadlib = function() return refuse("package.loadlib") end
          package.cpath = ""
          local searchers = package.searchers
          if type(searchers) == "table" then
            for i = #searchers, 3, -1 do searchers[i] = nil end
          end

          load = function(chunk, name, mode, ...)
            if select("#", ...) > 0 then return raw_load(chunk, name, "t", ...) end
            return raw_load(chunk, name, "t")
          end
          loadfile = function(path, mode, ...)
            if not permitted(path) then return refuse(path) end
            if select("#", ...) > 0 then return raw_loadfile(path, "t", ...) end
            return raw_loadfile(path, "t")
          end
          dofile = function(path)
            if not permitted(path) then raise(path) end
            local chunk, message = raw_loadfile(path, "t")
            if not chunk then error(message, 2) end
            return chunk()
          end

          -- debug.getupvalue/setupvalue/getlocal/sethook would expose the raw functions above.
          local raw_debug = debug
          local safe_debug = {}
          if type(raw_debug) == "table" then
            safe_debug.traceback = raw_debug.traceback
            safe_debug.getinfo = raw_debug.getinfo
          end
          debug = safe_debug
          if type(package.loaded) == "table" then package.loaded.debug = safe_debug end
        end

        """#

    static let loader = #"""
        if __keyboard_sandbox_source then
          local chunk, message = load(__keyboard_sandbox_source, "@rime.lua", "t")
          __keyboard_sandbox_source = nil
          if not chunk then error(message, 0) end
          return chunk()
        end
        __keyboard_sandbox_source = nil

        """#
}
