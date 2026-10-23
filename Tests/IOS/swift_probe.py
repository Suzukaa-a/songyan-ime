"""Shared compiler and scratch lifecycle for production-source Swift probes."""
import fcntl
import hashlib
import json
import os
import platform
import subprocess
import tempfile
from contextlib import contextmanager
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Packages/KeyboardCore/Sources/KeyboardCore"


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


def type_sources(directory, stem):
    """`Stem.swift` and its `Stem+*.swift` extension files, main file first."""
    return [directory / f"{stem}.swift", *sorted(directory.glob(f"{stem}+*.swift"))]


def type_source_text(directory, stem):
    return "\n".join(path.read_text(encoding="utf-8") for path in type_sources(directory, stem))


def controller_sources(directory):
    """Every production KeyboardController file, with UIKit swapped for the macOS QuartzCore seam."""
    paths = []
    for source in type_sources(ROOT / "Apps/SharedKeyboard", "KeyboardController"):
        target = directory / source.name
        target.write_text(source.read_text(encoding="utf-8").replace("import UIKit", "import QuartzCore"),
                          encoding="utf-8")
        paths.append(target)
    return paths


def swift_environment():
    env = dict(os.environ)
    if "DEVELOPER_DIR" not in env and env.get("XCODE_DEV_DIR"):
        env["DEVELOPER_DIR"] = env["XCODE_DEV_DIR"]
    return env


@contextmanager
def scratch_directory(prefix):
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=prefix + "-", dir=scratch) as directory:
        yield Path(directory)


def run(command, **kwargs):
    if os.environ.get("CI_SWIFTPM_DISABLE_SANDBOX") == "1" and list(command[:2]) == ["xcrun", "swiftc"]:
        command = [*command[:2], "-disable-sandbox", *command[2:]]
    result = subprocess.run(command, capture_output=True, text=True,
                            env=swift_environment(), timeout=180, **kwargs)
    if result.returncode:
        raise AssertionError(
            f"Command failed ({result.returncode}): {' '.join(map(str, command))}\n"
            + result.stdout + result.stderr)
    return result.stdout


MODULES = (("KeyboardCore", ()), ("LayoutKit", ()),
           ("CandidateKit", ("KeyboardCore", "LayoutKit")))
# Packages match their Package.swift (Swift 6); probe mains stay Swift 5 for their global test doubles.
MODULE_FLAGS = ("-swift-version", "6", "-parse-as-library", "-emit-library", "-emit-module")


@lru_cache(maxsize=1)
def toolchain_identity():
    # Versions/builds detect Xcode upgrades at the same path. Keep the resolved
    # compiler and SDK paths too: module imports and #filePath depend on paths.
    return {
        "compiler": run(["xcrun", "--find", "swiftc"]).strip(),
        "version": run(["xcrun", "swiftc", "-version"]),
        "sdk": run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip(),
        "sdkVersion": run(["xcrun", "--sdk", "macosx", "--show-sdk-version"]).strip(),
        "sdkBuild": run(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]).strip(),
        "architecture": platform.machine(),
    }


def module_cache_key(sources, identity, environment):
    inputs = {
        "implementation": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "toolchain": identity,
        "flags": MODULE_FLAGS,
        "modules": MODULES,
        "environment": {name: environment.get(name, "") for name in
                        ("DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS", "SWIFT_EXEC", "PATH",
                         "CI_SWIFTPM_DISABLE_SANDBOX")},
        "sources": [(str(path), hashlib.sha256(content).hexdigest())
                    for path, content in sources],
    }
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def module_artifacts():
    return [f"{name}{suffix}" if suffix != ".dylib" else f"lib{name}.dylib"
            for name, _ in MODULES
            for suffix in (".swiftmodule", ".swiftdoc", ".swiftsourceinfo", ".dylib")]


def module_cache_is_valid(directory):
    try:
        recorded = json.loads((directory / "complete.json").read_text())
        expected = module_artifacts()
        return (set(recorded) == set(expected)
                and all(hashlib.sha256((directory / name).read_bytes()).hexdigest() == recorded[name]
                        for name in expected))
    except (OSError, ValueError, TypeError):
        return False


def module_sources():
    return [(path, path.read_bytes()) for name, _ in MODULES
            for path in sorted((ROOT / f"Packages/{name}/Sources/{name}").rglob("*.swift"))]


def production_modules():
    """Reuse exact production modules; every caller still builds/runs its probe."""
    sources = module_sources()
    identity = toolchain_identity()
    key = module_cache_key(sources, identity, swift_environment())
    directory = ROOT / ".local/swift-probes/modules" / key
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "build.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if module_sources() != sources:
            raise AssertionError("Production module sources changed while waiting for the build lock; rerun the gate")
        if module_cache_is_valid(directory):
            return directory
        # Never leave a success marker for a failed/partial rebuild.
        marker = directory / "complete.json"
        marker.unlink(missing_ok=True)
        for name, dependencies in MODULES:
            paths = [path for path, _ in sources
                     if path.is_relative_to(ROOT / f"Packages/{name}/Sources/{name}")]
            run(["xcrun", "swiftc", *MODULE_FLAGS, "-module-name", name,
                 "-sdk", identity["sdk"], "-I", str(directory), "-L", str(directory),
                 "-module-cache-path", str(directory / "module-cache"),
                 *[f"-l{dependency}" for dependency in dependencies], *map(str, paths),
                 "-emit-module-path", str(directory / f"{name}.swiftmodule"),
                 "-o", str(directory / f"lib{name}.dylib")])
        if module_sources() != sources:
            raise AssertionError("Production module sources changed during compilation; rerun the gate")
        hashes = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
                  for name in module_artifacts()}
        temporary = directory / "complete.json.tmp"
        temporary.write_text(json.dumps(hashes, sort_keys=True) + "\n")
        temporary.replace(marker)
    return directory


def compile_swift(directory, sources, *, library=False, dependencies=()):
    binary = directory / "probe"
    flags = ["-parse-as-library"] if library else []
    if dependencies:
        modules = production_modules()
        flags += ["-I", str(modules), "-L", str(modules),
                  *[f"-l{name}" for name in dependencies],
                  "-Xlinker", "-rpath", "-Xlinker", str(modules)]
    run(["xcrun", "swiftc", "-swift-version", "5", *flags,
         *map(str, sources), "-o", str(binary)])
    return binary


def run_swift(module, checks, *, prefix, library=False, dependencies=()):
    with scratch_directory(prefix) as directory:
        source = directory / "Production.swift"
        main = directory / ("Probe.swift" if library else "main.swift")
        source.write_text(module, encoding="utf-8")
        main.write_text(checks, encoding="utf-8")
        binary = compile_swift(directory, [source, main], library=library, dependencies=dependencies)
        runtime = directory / "runtime"
        runtime.mkdir()
        return run([str(binary), str(runtime)])


def without_imports(text):
    return "".join(line for line in text.splitlines(keepends=True) if not line.startswith("import "))


def recipe_store_source():
    shared = ROOT / "Apps/SharedKeyboard"
    paths = (shared / "RimePaths.swift").read_text()
    engine_types = (CORE / "Engine/EngineTypes.swift").read_text()
    declarations = [
        (CORE / "Layout/KeyboardLayout.swift").read_text().split("// MARK: - Key actions and keycaps", 1)[0],
        section(engine_types, "public struct KeyboardSchemaDescriptor",
                "\npublic struct KeyboardSelectionChange"),
    ]
    for path in [
        "Engine/KeyboardResourceSet.swift", "Support/GrammarModelPath.swift",
        "Engine/PublishedKeyboard.swift", "Engine/PublishedKeyboardRoster.swift",
        "Engine/KeyboardPublicationSource.swift", "Engine/UserKeyboardPublicationTransaction.swift",
        "Support/UserTerminology.swift", "Support/RefreshCoordination.swift",
        "Support/BoundedFileRead.swift", "Support/ProductionInputAvailability.swift",
        "Engine/KeyboardRouteIdentity.swift",
    ]:
        declarations.append((CORE / path).read_text())
    declarations.append(section(paths, "extension KeyboardRecipeStore {", "\n// MARK: - DIY"))
    for name in ["KeyboardRecipeStore.swift", "KeyboardRecipeStore+Publication.swift",
                 "GrammarRuntimeReceiptStore.swift", "EngineOpQueue.swift"]:
        declarations.append(without_imports((shared / name).read_text()))
    declarations.append((ROOT / "Apps/SharedKeyboard/KeyboardLog.swift").read_text().replace("import OSLog\n", ""))
    shim = (ROOT / "Tests/IOS/Fixtures/RimeConfigShim.swift").read_text()
    return "import Foundation\nimport CryptoKit\nimport OSLog\n" + shim + "\n" + "\n".join(declarations)
