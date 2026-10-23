#!/usr/bin/env python3
"""Summarize an xctrace Time Profiler (+ os_signpost) recording of the keyboard extension.

Inputs are the XML exports written by `sim-perf.sh`:
  * signposts.xml  - os-signpost table (UIKit `UpdateSequence`, CoreAnimation commits,
                     and in Debug the project's `DebugProbe` key/refresh/engineOp intervals);
  * profile.xml    - time-profile table (1 ms samples, user call stacks).

Prints per-key main-thread CPU, update-cycle duration percentiles and a coarse
attribution of main-thread samples. Only technical frame names and timings are read;
no user text is present in either table.

Usage: perf_trace.py <signposts.xml> <profile.xml> <key-count> [--top N]
"""
import argparse
import collections
import xml.etree.ElementTree as ET

# Ordered: a sample is attributed to the first matching bucket.
CATEGORIES = (
    ("engine (RimeBackend)", "RimeBackend."),
    ("touch hit-test", "FeedbackInputView.hitTest"),
    ("KeyboardController.handle", "KeyboardController.handle"),
    ("SwiftUI view-graph update", "_updateViewGraph"),
    ("SwiftUI render/layout", "ViewGraphRootValueUpdater.render"),
    ("CoreAnimation commit", "CA::Transaction::commit"),
)
MARKERS = ("definitionKey", "KeyAreaRenderGate")


class Refs:
    """xctrace exports intern repeated values as id/ref; resolve them."""

    def __init__(self):
        self.ids = {}

    def register(self, element):
        if element.get("id"):
            self.ids[element.get("id")] = element
        for child in element:
            self.register(child)

    def resolve(self, element):
        ref = element.get("ref")
        return self.ids[ref] if ref else element


def percentile(values, p):
    return values[min(len(values) - 1, int(len(values) * p))] if values else 0.0


def signpost_intervals(path):
    root = ET.parse(path).getroot()
    refs = Refs()
    pending, intervals = {}, collections.defaultdict(list)
    for row in root.iter("row"):
        refs.register(row)
        cells = [refs.resolve(cell) for cell in row]
        if len(cells) < 11:
            continue
        time = int(cells[0].text)
        event = cells[3].get("fmt")
        ident = cells[5].text
        name = cells[6].get("fmt")
        category = cells[10].get("fmt") or ""
        key = (category, name, ident)
        if event == "Begin":
            pending[key] = time
        elif event == "End" and key in pending:
            intervals[(category, name)].append((time - pending.pop(key)) / 1e6)
    return intervals


def main_thread_samples(path):
    root = ET.parse(path).getroot()
    refs = Refs()
    total, buckets, markers = 0, collections.Counter(), collections.Counter()
    for row in root.iter("row"):
        refs.register(row)
        cells = [refs.resolve(cell) for cell in row]
        if len(cells) < 2 or not (cells[1].get("fmt") or "").startswith("Main Thread"):
            continue
        stacks = [cell for cell in cells if cell.tag in ("backtrace", "tagged-backtrace")]
        if not stacks:
            continue
        names = " ".join(refs.resolve(frame).get("name") or "" for frame in stacks[0].iter("frame"))
        total += 1
        for label, needle in CATEGORIES:
            if needle in names:
                buckets[label] += 1
                break
        else:
            buckets["other"] += 1
        for marker in MARKERS:
            if marker in names:
                markers[marker] += 1
    return total, buckets, markers


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("signposts")
    parser.add_argument("profile")
    parser.add_argument("keys", type=int)
    args = parser.parse_args()

    intervals = signpost_intervals(args.signposts)
    updates = sorted(d for (category, name), values in intervals.items()
                     if name == "UpdateSequence" and category.startswith("UpdateCycle")
                     for d in values if d > 1.0)
    print(f"update cycles >1ms: n={len(updates)} sum={sum(updates):.0f}ms "
          f"p50={percentile(updates, .5):.1f} p95={percentile(updates, .95):.1f} "
          f"max={(updates[-1] if updates else 0):.1f}")
    for name in ("key", "refresh", "engineOp"):
        values = sorted(intervals.get(("DebugProbe", name), []))
        if values:
            print(f"DebugProbe {name}: n={len(values)} p50={percentile(values, .5):.2f} "
                  f"p95={percentile(values, .95):.2f} max={values[-1]:.2f} ms")

    total, buckets, markers = main_thread_samples(args.profile)
    keys = max(1, args.keys)
    print(f"main-thread samples={total} keys={args.keys} -> {total / keys:.2f} ms/key")
    for label, count in buckets.most_common():
        print(f"  {label:28s} {count / keys:6.2f} ms/key ({100 * count / max(1, total):4.1f}%)")
    for marker, count in markers.most_common():
        print(f"  [contains {marker}] {count / keys:.2f} ms/key")


if __name__ == "__main__":
    main()
