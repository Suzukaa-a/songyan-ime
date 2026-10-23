#!/usr/bin/env python3
"""Generate the keyboard click assets (soft/medium/strong).

The committed Resources/KeyFeedback/*.wav files are the sources the app uses;
the build does not run this script. Re-run it only to re-author the clicks:

    python3 Tools/KeyFeedbackAssets/generate_key_clicks.py

Each level is the same filtered noise burst (mono 16-bit 48 kHz, 20 ms) at a
different peak amplitude (about -20 / -14 / -8 dBFS), so only loudness differs.
"""

import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Resources" / "KeyFeedback"
SAMPLE_RATE = 48_000
DURATION_S = 0.020
DECAY_TAU_S = 0.006
LOWPASS_COEF = 0.35
LEVELS = {"soft": 0.10, "medium": 0.20, "strong": 0.40}


def one_pole_lowpass(samples, coef):
    result = []
    acc = 0.0
    for s in samples:
        acc += coef * (s - acc)
        result.append(acc)
    return result


def write_click(name, amplitude):
    rng = random.Random(20261016)
    total = int(SAMPLE_RATE * DURATION_S)
    samples = []
    for n in range(total):
        t = n / SAMPLE_RATE
        envelope = math.exp(-t / DECAY_TAU_S) * (1.0 - math.exp(-t / 0.0002))
        samples.append(rng.uniform(-1.0, 1.0) * envelope)
    samples = one_pole_lowpass(samples, LOWPASS_COEF)
    peak = max(abs(s) for s in samples)
    gain = amplitude / peak
    frames = b"".join(
        struct.pack("<h", max(-32767, min(32767, int(s * gain * 32767))))
        for s in samples
    )
    path = OUT / f"key-click-{name}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(frames)
    peak_dbfs = 20 * math.log10(amplitude)
    print(f"{path.name}: {total} samples, peak {peak_dbfs:.1f} dBFS")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, amplitude in LEVELS.items():
        write_click(name, amplitude)


if __name__ == "__main__":
    main()
