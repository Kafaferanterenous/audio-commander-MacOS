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

func checkInRange(_ label: String, _ lo: Double, _ hi: Double) {
    // placeholder not used
}

// MARK: - Option mapping

let expected: [CrossfadeOption: Double] = [
    .off: 0, .gapless: 0.08, .three: 3,
]
check("all three cases", CrossfadeOption.allCases.count == 3,
      "count \(CrossfadeOption.allCases.count)")
check("allCases cover 0...2", CrossfadeOption.allCases.map(\.rawValue).sorted() == [0, 1, 2])
for (opt, overlap) in expected {
    checkEqual("\(opt) overlap", opt.overlap, overlap)
}
check("off is disabled", !CrossfadeOption.off.isEnabled)
check("gapless is enabled", CrossfadeOption.gapless.isEnabled)
check("three is enabled", CrossfadeOption.three.isEnabled)
check("only gapless is gapless", CrossfadeOption.gapless.isGapless
      && !CrossfadeOption.off.isGapless && !CrossfadeOption.three.isGapless)
let keys = Set(CrossfadeOption.allCases.map(\.titleKey))
check("title keys unique", keys.count == CrossfadeOption.allCases.count)

print("--- \(checks) checks, \(failures) failures ---")
exit(failures == 0 ? 0 : 1)
