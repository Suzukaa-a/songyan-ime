// Checks for the extracted level enum and preferences store; the wrapper prepends
// the production source. Real Taptic strength and loudness need hardware.

extension KeyboardFeedbackPreferences {
    /// Points the store at an isolated suite.
    static func injectDefaultsForTesting(_ store: UserDefaults) {
        defaultsOverride = store
    }
}

func wavEnergy(_ url: URL) -> (peak: Double, rms: Double, duration: Double, sampleRate: Int) {
    let data = try! Data(contentsOf: url)
    func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    precondition(data.count > 44, "wav file too short")
    let riff = [UInt8](data.subdata(in: 0..<4))
    precondition(riff == [UInt8]("RIFF".utf8), "not a RIFF wav")
    var offset = 12
    var sampleRate = 0
    var bits = 0
    var samples: [Double] = []
    while offset + 8 <= data.count {
        let id = [UInt8](data.subdata(in: offset..<offset + 4))
        let size = u32(offset + 4)
        if id == [UInt8]("fmt ".utf8) {
            sampleRate = u16(offset + 12)
            bits = u16(offset + 22)
        } else if id == [UInt8]("data".utf8) {
            let bytesPerFrame = max(1, bits / 8)
            let frames = size / bytesPerFrame
            samples.reserveCapacity(frames)
            for f in 0..<frames {
                let base = offset + 8 + f * bytesPerFrame
                let value = Int16(bitPattern: UInt16(u16(base)))
                samples.append(Double(value) / 32767.0)
            }
        }
        offset += 8 + size + (size % 2)
    }
    precondition(bits == 16 && !samples.isEmpty, "expected 16-bit PCM click asset")
    let peak = samples.map { abs($0) }.max() ?? 0
    let energy = samples.reduce(0.0) { $0 + $1 * $1 }
    let rms = (energy / Double(samples.count)).squareRoot()
    return (peak, rms, Double(samples.count) / Double(sampleRate), sampleRate)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    precondition(actual == expected, message + " (expected \(expected), got \(actual))")
}

// Resolve: missing and unknown stored values fall back to the medium default,
// so no stored value can produce an undefined strength.
expectEqual(KeyboardFeedbackLevel.resolve(nil), .medium, "missing stored level resolves to medium")
expectEqual(KeyboardFeedbackLevel.resolve("nonsense"), .medium, "unknown stored level resolves to medium")
expectEqual(KeyboardFeedbackLevel.resolve("soft"), .soft, "known raw value resolves to itself")
expectEqual(KeyboardFeedbackLevel.resolve("medium"), .medium, "known raw value resolves to itself")
expectEqual(KeyboardFeedbackLevel.resolve("strong"), .strong, "known raw value resolves to itself")

// Fresh store: medium levels, switches keep their pre-level defaults.
let domain = "test.keyboard.feedback.levels." + UUID().uuidString
let suite = UserDefaults(suiteName: domain)!
KeyboardFeedbackPreferences.injectDefaultsForTesting(suite)
expectEqual(KeyboardFeedbackPreferences.soundLevel, .medium, "sound level default is medium")
expectEqual(KeyboardFeedbackPreferences.hapticLevel, .medium, "haptic level default is medium")
expectEqual(KeyboardFeedbackPreferences.soundEnabled, true, "sound stays default-on")
expectEqual(KeyboardFeedbackPreferences.hapticEnabled, false, "haptics stay default-off")
precondition(
    suite.object(forKey: KeyboardFeedbackPreferences.soundLevelKey) == nil,
    "default medium is not written until the user chooses")
precondition(
    suite.object(forKey: KeyboardFeedbackPreferences.hapticLevelKey) == nil,
    "default medium is not written until the user chooses")

// Write/read round trip through the same App Group keys, switches untouched.
KeyboardFeedbackPreferences.soundLevel = .soft
KeyboardFeedbackPreferences.hapticLevel = .strong
expectEqual(suite.string(forKey: KeyboardFeedbackPreferences.soundLevelKey), "soft", "sound level stores its raw value")
expectEqual(
    suite.string(forKey: KeyboardFeedbackPreferences.hapticLevelKey), "strong", "haptic level stores its raw value")
precondition(
    suite.object(forKey: KeyboardFeedbackPreferences.soundKey) == nil,
    "level writes never touch the sound switch")
precondition(
    suite.object(forKey: KeyboardFeedbackPreferences.hapticKey) == nil,
    "level writes never touch the haptic switch")

// Explicit switches are independent of the levels.
KeyboardFeedbackPreferences.soundEnabled = false
KeyboardFeedbackPreferences.hapticEnabled = true
expectEqual(KeyboardFeedbackPreferences.soundEnabled, false, "explicit switch survives level writes")
expectEqual(KeyboardFeedbackPreferences.hapticEnabled, true, "explicit switch survives level writes")
KeyboardFeedbackPreferences.soundEnabled = true
KeyboardFeedbackPreferences.hapticEnabled = false

// Read-only (a keyboard without Full Access): changes hold for this process only.
KeyboardRecipeStore.canWriteSharedContainer = false
KeyboardFeedbackPreferences.hapticEnabled = true
KeyboardFeedbackPreferences.soundLevel = .strong
expectEqual(KeyboardFeedbackPreferences.hapticEnabled, true, "read-only change holds in the process")
expectEqual(KeyboardFeedbackPreferences.soundLevel, .strong, "read-only level holds in the process")
expectEqual(suite.object(forKey: KeyboardFeedbackPreferences.hapticKey) as? Bool, false, "read-only never writes")
expectEqual(suite.string(forKey: KeyboardFeedbackPreferences.soundLevelKey), "soft", "read-only never writes")
KeyboardRecipeStore.canWriteSharedContainer = true
KeyboardFeedbackPreferences.hapticEnabled = false
KeyboardFeedbackPreferences.soundLevel = .soft

// User-facing names are exactly 弱/适中/强.
expectEqual(KeyboardFeedbackLevel.soft.displayName, "弱", "soft label")
expectEqual(KeyboardFeedbackLevel.medium.displayName, "适中", "medium label")
expectEqual(KeyboardFeedbackLevel.strong.displayName, "强", "strong label")

// Mapped parameters strictly increase with the level: the presets are real
// differences, not three names for one feel. Fallback styles also differ per
// level, so even the UIFeedbackGenerator-only path keeps the three distinct.
let all = Array(KeyboardFeedbackLevel.allCases)
precondition(all == [.soft, .medium, .strong], "level order is 弱/适中/强")
for i in 0..<(all.count - 1) {
    let lower = all[i]
    let higher = all[i + 1]
    precondition(lower.hapticIntensity < higher.hapticIntensity, "haptic intensity must rise with the level")
    precondition(lower.hapticSharpness < higher.hapticSharpness, "haptic sharpness must rise with the level")
    precondition(
        lower.fallbackImpactIntensity < higher.fallbackImpactIntensity, "fallback intensity must rise with the level")
    precondition(lower.fallbackImpactStyle != higher.fallbackImpactStyle, "fallback styles must differ per level")
}
// Medium must equal the fixed feel shipped before levels (0.55/0.60, light), so
// an upgrade does not change existing feedback until the user picks a strength.
expectEqual(KeyboardFeedbackLevel.medium.hapticIntensity, Float(0.55), "medium keeps the shipped intensity")
expectEqual(KeyboardFeedbackLevel.medium.hapticSharpness, Float(0.6), "medium keeps the shipped sharpness")
let mediumStyle = KeyboardFeedbackLevel.medium.fallbackImpactStyle
let strongStyle = KeyboardFeedbackLevel.strong.fallbackImpactStyle
precondition(mediumStyle == UIImpactFeedbackGenerator.FeedbackStyle.light, "medium keeps the shipped fallback style")
precondition(strongStyle == UIImpactFeedbackGenerator.FeedbackStyle.heavy, "strong falls back to the heavier style")

// Public API domains: CoreHaptics and impact intensity are bounded to 0...1.
for level in all {
    precondition((0.0...1.0).contains(Double(level.hapticIntensity)), "intensity within public domain")
    precondition((0.0...1.0).contains(Double(level.hapticSharpness)), "sharpness within public domain")
    precondition((0.0...1.0).contains(Double(level.fallbackImpactIntensity)), "impact intensity within public domain")
}

// Settings cycle order: 弱 → 适中 → 强 → 弱.
expectEqual(KeyboardFeedbackLevel.soft.next, .medium, "cycle soft")
expectEqual(KeyboardFeedbackLevel.medium.next, .strong, "cycle medium")
expectEqual(KeyboardFeedbackLevel.strong.next, .soft, "cycle strong")

// Each level's asset is clearly louder than the one below at identical timing.
func assetURL(_ level: KeyboardFeedbackLevel, root: URL) -> URL {
    root.appendingPathComponent("Resources/KeyFeedback/key-click-" + level.rawValue + ".wav")
}
let repoRoot = URL(fileURLWithPath: "__ROOT__")
var previous: (peak: Double, rms: Double, duration: Double, sampleRate: Int)?
for level in all {
    let metrics = wavEnergy(assetURL(level, root: repoRoot))
    precondition(metrics.peak > 0 && metrics.rms > 0, level.rawValue + " asset carries audio energy")
    print(
        String(
            format: "%@: peak %.4f rms %.5f %.1f ms @ %d Hz", level.rawValue, metrics.peak, metrics.rms,
            metrics.duration * 1000, metrics.sampleRate))
    if let before = previous {
        precondition(metrics.peak > before.peak * 1.5, level.rawValue + " peak must clearly exceed the weaker level")
        precondition(metrics.rms > before.rms * 1.5, level.rawValue + " energy must clearly exceed the weaker level")
        precondition(abs(metrics.duration - before.duration) < 0.002, level.rawValue + " keeps the same click timing")
        precondition(metrics.sampleRate == before.sampleRate, level.rawValue + " keeps the same sample rate")
    }
    previous = metrics
}
precondition((previous?.duration ?? 1) < 0.05, "click stays a click (well under 50 ms)")

print("feedback levels checks passed: bounds/fallback/monotonic/assets")
