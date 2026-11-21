import Foundation

let noiseLabel = "noise"

enum ModelKind: String, Codable, CaseIterable, Identifiable {
    case logreg, knn, centroid, svm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .svm: "Support vector machine"
        case .logreg: "Logistic regression"
        case .knn: "Nearest neighbours"
        case .centroid: "Nearest centroid"
        }
    }
}

/// Deterministic RNG so cross-validation results are stable between runs.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Standardise each feature, then apply the feature-group weights.
struct Standardizer {
    var mean: [Double], scale: [Double]

    init(fit X: [[Double]]) {
        let d = X.first?.count ?? 0, n = Double(max(X.count, 1))
        let mu = (0..<d).map { j in X.reduce(0) { $0 + $1[j] } / n }
        mean = mu
        scale = (0..<d).map { j in
            let s = (X.reduce(0) { $0 + ($1[j] - mu[j]) * ($1[j] - mu[j]) } / n).squareRoot()
            return s > 1e-12 ? s : 1
        }
    }

    func transform(_ x: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let w: Double = i < Features.weights.count ? Features.weights[i] : 1
            out[i] = w * (x[i] - mean[i]) / scale[i]
        }
        return out
    }
}

protocol ZoneClassifier {
    /// Class probabilities for an already-standardised sample.
    func probabilities(_ z: [Double]) -> [Double]
}

@inline(__always) private func distance(_ a: [Double], _ b: [Double]) -> Double {
    var s = 0.0
    for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }
    return s.squareRoot()
}

struct NearestNeighbours: ZoneClassifier {
    let Z: [[Double]], y: [Int], classes: Int, k = 3

    func probabilities(_ z: [Double]) -> [Double] {
        let nearest = Z.indices.map { (distance(Z[$0], z), y[$0]) }.sorted { $0.0 < $1.0 }.prefix(k)
        var votes = Array(repeating: 0.0, count: classes)
        if let exact = nearest.first(where: { $0.0 < 1e-12 }) {
            votes[exact.1] = 1
            return votes
        }
        for (d, c) in nearest { votes[c] += 1 / d }
        let total = votes.reduce(0, +)
        return votes.map { $0 / total }
    }
}

struct NearestCentroid: ZoneClassifier {
    let centroids: [[Double]]

    init(Z: [[Double]], y: [Int], classes: Int) {
        let d = Z.first?.count ?? 0
        centroids = (0..<classes).map { c in
            let members = Z.indices.filter { y[$0] == c }.map { Z[$0] }
            return (0..<d).map { j in members.reduce(0) { $0 + $1[j] } / Double(max(members.count, 1)) }
        }
    }

    func probabilities(_ z: [Double]) -> [Double] {
        let s = centroids.map { -distance($0, z) }
        let m = s.max() ?? 0
        let e = s.map { exp($0 - m) }
        let total = e.reduce(0, +)
        return e.map { $0 / total }
    }
}

/// Multinomial logistic regression with L2 (sklearn's C = 1), trained by full-batch Adam.
struct SoftmaxRegression: ZoneClassifier {
    var W: [[Double]], b: [Double]

    init(Z: [[Double]], y: [Int], classes: Int, iterations: Int = 300) {
        let n = Z.count, d = Z.first?.count ?? 0
        W = Array(repeating: Array(repeating: 0, count: d), count: classes)
        b = Array(repeating: 0, count: classes)
        let lambda = 1.0 / Double(max(n, 1))
        var mW = W, vW = W, mb = b, vb = b
        let lr = 0.05, b1 = 0.9, b2 = 0.999, eps = 1e-8
        var p = Array(repeating: 0.0, count: classes)
        for step in 1...iterations {
            var gW = Array(repeating: Array(repeating: 0.0, count: d), count: classes)
            var gb = Array(repeating: 0.0, count: classes)
            for i in 0..<n {
                let z = Z[i]
                var m = -Double.infinity
                for c in 0..<classes {
                    var s = b[c]
                    let w = W[c]
                    for j in 0..<d { s += w[j] * z[j] }
                    p[c] = s
                    m = max(m, s)
                }
                var total = 0.0
                for c in 0..<classes { p[c] = exp(p[c] - m); total += p[c] }
                for c in 0..<classes {
                    let err = p[c] / total - (y[i] == c ? 1 : 0)
                    if err == 0 { continue }
                    gb[c] += err
                    for j in 0..<d { gW[c][j] += err * z[j] }
                }
            }
            let inv = 1.0 / Double(n)
            let c1 = 1 - pow(b1, Double(step)), c2 = 1 - pow(b2, Double(step))
            for c in 0..<classes {
                for j in 0..<d {
                    let g = gW[c][j] * inv + lambda * W[c][j]
                    mW[c][j] = b1 * mW[c][j] + (1 - b1) * g
                    vW[c][j] = b2 * vW[c][j] + (1 - b2) * g * g
                    W[c][j] -= lr * (mW[c][j] / c1) / ((vW[c][j] / c2).squareRoot() + eps)
                }
                let g = gb[c] * inv
                mb[c] = b1 * mb[c] + (1 - b1) * g
                vb[c] = b2 * vb[c] + (1 - b2) * g * g
                b[c] -= lr * (mb[c] / c1) / ((vb[c] / c2).squareRoot() + eps)
            }
        }
    }

    func probabilities(_ z: [Double]) -> [Double] {
        let s = (0..<W.count).map { c in zip(W[c], z).reduce(b[c]) { $0 + $1.0 * $1.1 } }
        let m = s.max() ?? 0
        let e = s.map { exp($0 - m) }
        let total = e.reduce(0, +)
        return e.map { $0 / total }
    }
}

/// Support vector machine with an RBF kernel: libsvm's algorithm (SMO with second-order working-set selection),
/// one-vs-one, C = 3 and scikit-learn's gamma = "scale" (1 / total feature variance, so it adapts to each Mac's taps).
///
/// A tap's twist pattern doesn't split the zones along straight lines; the kernel lets the boundary bend around
/// each zone's cluster. On real recorded taps it cut cross-validated errors by a third to two thirds compared with
/// logistic regression. Pairwise outputs become class probabilities through a fixed sigmoid and libsvm's pairwise
/// coupling, so the "act only when this sure" floor keeps its meaning.
struct SupportVectorMachine: ZoneClassifier {
    static let C = 3.0
    /// Sigmoid slope for a pairwise decision value. Chosen on recorded taps (scripts/eval.sh) so that, with the
    /// default 60% floor, the SVM acts on more taps than logistic regression while doing the wrong thing half as often.
    static let slope = 6.0

    let Z: [[Double]], gamma: Double, classes: Int
    /// For each class pair (a < b): training indices, their coefficients (alpha · y) and the bias.
    let pairs: [(a: Int, b: Int, index: [Int], coef: [Double], rho: Double)]

    init(Z: [[Double]], y: [Int], classes: Int) {
        let n = Z.count, d = Z.first?.count ?? 0
        var variance = 0.0
        for j in 0..<d {
            var s = 0.0, s2 = 0.0
            for z in Z { s += z[j]; s2 += z[j] * z[j] }
            let m = s / Double(max(n, 1))
            variance += s2 / Double(max(n, 1)) - m * m
        }
        let gamma = variance > 1e-12 ? 1 / variance : 1
        var K = [[Double]](repeating: [Double](repeating: 1, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) {
                let v = exp(-gamma * Self.squaredDistance(Z[i], Z[j]))
                K[i][j] = v
                K[j][i] = v
            }
        }
        var pairs: [(Int, Int, [Int], [Double], Double)] = []
        for a in 0..<classes {
            for b in (a + 1)..<max(classes, a + 1) {
                let idx = (0..<n).filter { y[$0] == a || y[$0] == b }
                let sign = idx.map { y[$0] == a ? 1.0 : -1.0 }
                let (alpha, rho) = Self.solve(K: K, index: idx, y: sign, C: Self.C)
                var keep: [Int] = [], coef: [Double] = []
                for t in idx.indices where alpha[t] > 0 { keep.append(idx[t]); coef.append(alpha[t] * sign[t]) }
                pairs.append((a, b, keep, coef, rho))
            }
        }
        self.Z = Z
        self.gamma = gamma
        self.classes = classes
        self.pairs = pairs
    }

    @inline(__always) static func squaredDistance(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }
        return s
    }

    /// Binary C-SVM dual, solved as in libsvm's Solver (WSS 2, Fan, Chen & Lin 2005). Returns alphas and rho.
    static func solve(K: [[Double]], index: [Int], y: [Double], C: Double, eps: Double = 1e-3) -> ([Double], Double) {
        let n = index.count, tau = 1e-12
        var alpha = [Double](repeating: 0, count: n)
        var G = [Double](repeating: -1, count: n)
        func q(_ i: Int, _ j: Int) -> Double { y[i] * y[j] * K[index[i]][index[j]] }
        func upper(_ t: Int) -> Bool { alpha[t] >= C }
        func lower(_ t: Int) -> Bool { alpha[t] <= 0 }
        var iterations = 0
        while iterations < max(10_000_000 / max(n, 1), 100 * n) {
            iterations += 1
            // Pick i: the most violating index from the "up" set.
            var gmax = -Double.infinity, i = -1
            for t in 0..<n {
                if y[t] > 0 { if !upper(t) && -G[t] >= gmax { gmax = -G[t]; i = t } }
                else if !lower(t) && G[t] >= gmax { gmax = G[t]; i = t }
            }
            guard i >= 0 else { break }
            // Pick j by the largest second-order decrease of the objective.
            var gmax2 = -Double.infinity, j = -1, best = Double.infinity
            for t in 0..<n {
                let kit = K[index[i]][index[t]]
                if y[t] > 0 {
                    guard !lower(t) else { continue }
                    let diff = gmax + G[t]
                    gmax2 = max(gmax2, G[t])
                    if diff > 0 {
                        let quad = 2 - 2 * y[i] * kit
                        let obj = -diff * diff / (quad > 0 ? quad : tau)
                        if obj <= best { best = obj; j = t }
                    }
                } else {
                    guard !upper(t) else { continue }
                    let diff = gmax - G[t]
                    gmax2 = max(gmax2, -G[t])
                    if diff > 0 {
                        let quad = 2 + 2 * y[i] * kit
                        let obj = -diff * diff / (quad > 0 ? quad : tau)
                        if obj <= best { best = obj; j = t }
                    }
                }
            }
            if gmax + gmax2 < eps || j < 0 { break }

            let oldI = alpha[i], oldJ = alpha[j], qij = q(i, j)
            if y[i] != y[j] {
                var quad = 2 + 2 * qij
                if quad <= 0 { quad = tau }
                let delta = (-G[i] - G[j]) / quad, diff = alpha[i] - alpha[j]
                alpha[i] += delta; alpha[j] += delta
                if diff > 0 { if alpha[j] < 0 { alpha[j] = 0; alpha[i] = diff } }
                else if alpha[i] < 0 { alpha[i] = 0; alpha[j] = -diff }
                if diff > 0 { if alpha[i] > C { alpha[i] = C; alpha[j] = C - diff } }
                else if alpha[j] > C { alpha[j] = C; alpha[i] = C + diff }
            } else {
                var quad = 2 - 2 * qij
                if quad <= 0 { quad = tau }
                let delta = (G[i] - G[j]) / quad, sum = alpha[i] + alpha[j]
                alpha[i] -= delta; alpha[j] += delta
                if sum > C { if alpha[i] > C { alpha[i] = C; alpha[j] = sum - C } }
                else if alpha[j] < 0 { alpha[j] = 0; alpha[i] = sum }
                if sum > C { if alpha[j] > C { alpha[j] = C; alpha[i] = sum - C } }
                else if alpha[i] < 0 { alpha[i] = 0; alpha[j] = sum }
            }
            let dI = alpha[i] - oldI, dJ = alpha[j] - oldJ
            for t in 0..<n { G[t] += q(i, t) * dI + q(j, t) * dJ }
        }
        // rho: the average of y·G over free vectors, or the middle of the feasible range if none are free.
        var ub = Double.infinity, lb = -Double.infinity, free = 0, sum = 0.0
        for t in 0..<n {
            let yg = y[t] * G[t]
            if upper(t) { if y[t] < 0 { ub = min(ub, yg) } else { lb = max(lb, yg) } }
            else if lower(t) { if y[t] > 0 { ub = min(ub, yg) } else { lb = max(lb, yg) } }
            else { free += 1; sum += yg }
        }
        return (alpha, free > 0 ? sum / Double(free) : (ub + lb) / 2)
    }

    /// Pairwise decision values, positive when the tap looks like the pair's first class.
    func decisions(_ z: [Double]) -> [Double] {
        var k = [Double](repeating: .nan, count: Z.count)
        return pairs.map { p in
            var f = -p.rho
            for (i, c) in zip(p.index, p.coef) {
                if k[i].isNaN { k[i] = exp(-gamma * Self.squaredDistance(Z[i], z)) }
                f += c * k[i]
            }
            return f
        }
    }

    func probabilities(_ z: [Double]) -> [Double] {
        guard classes > 1 else { return [1] }
        var r = [[Double]](repeating: [Double](repeating: 0, count: classes), count: classes)
        for (p, f) in zip(pairs, decisions(z)) {
            let s = min(max(1 / (1 + exp(-Self.slope * f)), 1e-7), 1 - 1e-7)
            r[p.a][p.b] = s
            r[p.b][p.a] = 1 - s
        }
        return Self.couple(r)
    }

    /// libsvm's multiclass_probability (Wu, Lin & Weng 2004, method 2): class probabilities from pairwise ones.
    static func couple(_ r: [[Double]]) -> [Double] {
        let k = r.count
        var Q = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        for t in 0..<k {
            for j in 0..<k where j != t {
                Q[t][t] += r[j][t] * r[j][t]
                Q[t][j] = -r[j][t] * r[t][j]
            }
        }
        var p = [Double](repeating: 1 / Double(k), count: k)
        var Qp = [Double](repeating: 0, count: k)
        for _ in 0..<max(100, k) {
            var pQp = 0.0
            for t in 0..<k {
                Qp[t] = 0
                for j in 0..<k { Qp[t] += Q[t][j] * p[j] }
                pQp += p[t] * Qp[t]
            }
            if (0..<k).map({ abs(Qp[$0] - pQp) }).max()! < 0.005 / Double(k) { break }
            for t in 0..<k {
                let diff = (-Qp[t] + pQp) / Q[t][t]
                p[t] += diff
                pQp = (pQp + diff * (diff * Q[t][t] + 2 * Qp[t])) / ((1 + diff) * (1 + diff))
                for j in 0..<k {
                    Qp[j] = (Qp[j] + diff * Q[t][j]) / (1 + diff)
                    p[j] /= 1 + diff
                }
            }
        }
        return p
    }
}

func makeClassifier(_ kind: ModelKind, Z: [[Double]], y: [Int], classes: Int) -> ZoneClassifier {
    switch kind {
    case .knn: NearestNeighbours(Z: Z, y: y, classes: classes)
    case .centroid: NearestCentroid(Z: Z, y: y, classes: classes)
    case .logreg: SoftmaxRegression(Z: Z, y: y, classes: classes)
    case .svm: SupportVectorMachine(Z: Z, y: y, classes: classes)
    }
}

/// Fit scaler + classifier on (X, labels) plus each row's augmented variants, and predict labels for `test`.
func fitPredict(_ kind: ModelKind, X: [[Double]], labels: [String], test: [[Double]], augmented: [[[Double]]]? = nil) -> [String] {
    var X = X, labels = labels
    if let augmented {
        for (i, variants) in augmented.enumerated() { X += variants; labels += Array(repeating: labels[i], count: variants.count) }
    }
    let classes = Array(Set(labels)).sorted()
    let index = Dictionary(uniqueKeysWithValues: classes.enumerated().map { ($1, $0) })
    let scaler = Standardizer(fit: X)
    let Z = X.map(scaler.transform)
    let clf = makeClassifier(kind, Z: Z, y: labels.map { index[$0]! }, classes: classes.count)
    return test.map { x in
        let p = clf.probabilities(scaler.transform(x))
        return classes[p.indices.max { p[$0] < p[$1] }!]
    }
}
