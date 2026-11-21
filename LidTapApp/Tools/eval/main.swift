import Foundation

// Scores every recogniser on a recorded dataset, offline. The dataset is only read, never changed.
//   scripts/eval.sh [path/to/dataset.json]        default: this Mac's own calibration
//
// 1. Cross-validated accuracy per recogniser and layout, as Settings → Training reports it.
// 2. A live-use simulation: each held-out tap goes through the real ZoneModel with the default
//    "act only when this sure" floor and unfamiliar-tap rejection, and counts as right, wrong or "not sure".
//    It runs twice: with every zone on its own action, and with one action per row (top = Scroll Up,
//    bottom = Scroll Down), where zones that share an action are recognised as one group.

let path = CommandLine.arguments.dropFirst().first
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LidTap/dataset.json").path
let ds = try JSONDecoder().decode(Dataset.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
let limit = TapStrength.learned(from: ds.samples.filter { $0.label != noiseLabel }.map(\.peakG))
let samples = ds.samples.filter { $0.label == noiseLabel || $0.peakG >= limit }
let X = samples.map { Features.extract(g: $0.g, a: $0.a) }
let labels = samples.map(\.label)
let aug = samples.map { Augment.variants(of: $0) }
let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }
print("\(samples.count) usable taps of \(ds.samples.count) (strength limit \(String(format: "%.1f", limit)) °/s), \(ds.grid.title):",
      counts.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

let report = Evaluator.evaluate(X: X, labels: labels, grid: ds.grid, augmented: aug)
print("\nCross-validated accuracy")
print(pad("", 24) + report.layouts.map { pad($0, 14) }.joined())
for s in report.scores {
    print(pad(s.kind.title, 24) + report.layouts.map { pad(String(format: "%5.1f%%", 100 * (s.accuracy[$0] ?? 0)), 14) }.joined())
}
print("Automatic choice: \(report.best.title)")
print("Learning curve (taps per zone → accuracy): "
      + report.learning.map { "\($0.n) → \(String(format: "%.0f%%", 100 * $0.accuracy))" }.joined(separator: ", "))

/// The same stratified folds as Evaluator.crossValidate.
func folds() -> [Int] {
    var byClass: [String: [Int]] = [:]
    for (i, l) in labels.enumerated() { byClass[l, default: []].append(i) }
    let k = min(5, byClass.values.map(\.count).min() ?? 2)
    var rng = SplitMix64(seed: 0)
    var fold = Array(repeating: 0, count: labels.count)
    for key in byClass.keys.sorted() { for (j, i) in byClass[key]!.shuffled(using: &rng).enumerated() { fold[i] = j % k } }
    return fold
}

func simulate(_ kind: ModelKind, group: ((String) -> String)?) -> (right: Int, wrong: Int, unsure: Int, bumpsActed: Int) {
    let fold = folds(), defaults = AppConfig()
    let same: (String, String) -> Bool = { a, b in group.map { $0(a) == $0(b) } ?? (a == b) }
    var right = 0, wrong = 0, unsure = 0, bumps = 0
    for f in Set(fold).sorted() {
        let tr = labels.indices.filter { fold[$0] != f }
        let m = ZoneModel(kind: kind, X: tr.map { X[$0] }, labels: tr.map { labels[$0] }, augmented: tr.map { aug[$0] })
        for i in labels.indices where fold[i] == f {
            let p = m.predict(X[i], rejectFactor: defaults.rejectFactor, group: group)
            let acts = p.rejected == nil && p.confidence >= defaults.minConfidence
            if labels[i] == noiseLabel {
                if acts { bumps += 1 }
            } else if !acts {
                unsure += 1
            } else if same(p.label, labels[i]) {
                right += 1
            } else {
                wrong += 1
            }
        }
    }
    return (right, wrong, unsure, bumps)
}

let cols = ds.grid.cols
let byRow: (String) -> String = { label in zoneIndex(label).map { "row\($0 / cols)" } ?? label }
let zoneTaps = labels.filter { $0 != noiseLabel }.count
for (title, group) in [("every zone its own action", nil), ("one action per row, e.g. top Scroll Up, bottom Scroll Down", byRow)] {
    print("\nLive use, \(title) (\(zoneTaps) zone taps, \(labels.count - zoneTaps) bumps)")
    for kind in ModelKind.allCases {
        let r = simulate(kind, group: group)
        func pc(_ v: Int) -> String { String(format: "%5.1f%%", 100 * Double(v) / Double(max(zoneTaps, 1))) }
        print(pad(kind.title, 24) + "right \(pc(r.right))   wrong \(pc(r.wrong))   not sure \(pc(r.unsure))   bumps acted on: \(r.bumpsActed)")
    }
}
