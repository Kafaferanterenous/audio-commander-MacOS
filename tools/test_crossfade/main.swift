// Crossfade / gapless planning harness (#14).
//
// Compiles the production src/Crossfade.swift, so the option mapping and the
// fade math under test are the shipping code, not a copy.
//
// Build/run: ./tools/build_tools.sh && ./tools/test_crossfade

import Foundation

var checks = 0
var failures = 0

func check(_ label: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func checkEqual(_ label: String, _ got: Double, _ want: Double,
                _ detail: String = "") {
    check(label, abs(got - want) < 0.000_000_1,
          "\(detail.isEmpty ? "" : detail + " — ")got \(got), want \(want)")
}

func checkInRange(_ label: String, _ got: Double, _ lo: Double, _ hi: Double) {
    check(label, got >= lo && got <= hi, "got \(got), want \(lo)...\(hi)")
}

// MARK: - Option mapping

let expected: [CrossfadeOption: Double] = [
    .off: 0, .gapless: 0.08, .two: 2, .four: 4, .six: 6, .eight: 8,
]
check("all six cases", CrossfadeOption.allCases.count == 6,
      "count \(CrossfadeOption.allCases.count)")
check("allCases cover 0...5", CrossfadeOption.allCases.map(\.rawValue).sorted() == [0, 1, 2, 3, 4, 5])
for (opt, overlap) in expected {
    checkEqual("\(opt) overlap", opt.overlap, overlap)
}
check("off is disabled", !CrossfadeOption.off.isEnabled)
check("gapless is enabled", CrossfadeOption.gapless.isEnabled)
check("eight is enabled", CrossfadeOption.eight.isEnabled)
check("only gapless is gapless", CrossfadeOption.gapless.isGapless
      && !CrossfadeOption.off.isGapless && !CrossfadeOption.two.isGapless)
let keys = Set(CrossfadeOption.allCases.map(\.titleKey))
check("title keys unique", keys.count == CrossfadeOption.allCases.count)

// MARK: - shouldTransition

// Disabled overlap never fires.
check("off never triggers", !Crossfade.shouldTransition(position: 0, duration: 10, overlap: 0))
check("zero duration never triggers",
      !Crossfade.shouldTransition(position: 0, duration: 0, overlap: 4))

// Fires only inside the last `overlap` seconds.
check("fires exactly at boundary",
      Crossfade.shouldTransition(position: 6, duration: 10, overlap: 4))
check("fires just inside",
      Crossfade.shouldTransition(position: 9.99, duration: 10, overlap: 4))
check("does not fire before window",
      !Crossfade.shouldTransition(position: 5.99, duration: 10, overlap: 4))
check("does not fire at/past end",
      !Crossfade.shouldTransition(position: 10, duration: 10, overlap: 4))
check("does not fire past end",
      !Crossfade.shouldTransition(position: 12, duration: 10, overlap: 4))
check("short overlap window",
      Crossfade.shouldTransition(position: 9.97, duration: 10, overlap: 0.08)
      && !Crossfade.shouldTransition(position: 9.9, duration: 10, overlap: 0.08))

// MARK: - Fade math

checkEqual("fadeIn at 0", Crossfade.fadeIn(elapsed: 0, overlap: 4), 0)
checkEqual("fadeIn mid", Crossfade.fadeIn(elapsed: 2, overlap: 4), 0.5)
checkEqual("fadeIn at end", Crossfade.fadeIn(elapsed: 4, overlap: 4), 1)
checkEqual("fadeIn clips over", Crossfade.fadeIn(elapsed: 9, overlap: 4), 1)
checkEqual("fadeIn clamps negative", Crossfade.fadeIn(elapsed: -1, overlap: 4), 0)
checkEqual("fadeIn no overlap is 1", Crossfade.fadeIn(elapsed: 0, overlap: 0), 1)
checkEqual("fadeOut at 0", Crossfade.fadeOut(elapsed: 0, overlap: 4), 1)
checkEqual("fadeOut mid", Crossfade.fadeOut(elapsed: 2, overlap: 4), 0.5)
checkEqual("fadeOut at end", Crossfade.fadeOut(elapsed: 4, overlap: 4), 0)
check("fadeOut over never negative",
      Crossfade.fadeOut(elapsed: 9, overlap: 4) >= 0)
checkInRange("sum is 1 mid-fade",
             Crossfade.fadeIn(elapsed: 1.3, overlap: 4)
                 + Crossfade.fadeOut(elapsed: 1.3, overlap: 4), 0.999_999, 1.000_001)
checkInRange("sum is 1 late-fade",
             Crossfade.fadeIn(elapsed: 3.7, overlap: 4)
                 + Crossfade.fadeOut(elapsed: 3.7, overlap: 4), 0.999_999, 1.000_001)
checkEqual("gapless fades are instant-cross", Crossfade.fadeIn(elapsed: 0, overlap: 0.08), 0)

print("--- \(checks) checks, \(failures) failures ---")
exit(failures == 0 ? 0 : 1)