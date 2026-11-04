import SwiftUI
import Testing
@testable import TrainTracker

/// Renders the under-way progress bar a few times through its shimmer.
@MainActor
struct ShimmerRenderTests {
    @Test func rendersFramesOfTheSweep() async throws {
        var frames: [UIImage] = []
        for _ in 0..<6 {
            let bar = HStack(spacing: 0) {
                ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                    RouteLine(progress: 0.6, pulsing: true)
                        .frame(width: 300)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .environment(\.colorScheme, scheme)
                }
            }
            .tint(Color.trainTeal)
            let renderer = ImageRenderer(content: bar)
            renderer.scale = 4
            frames.append(try #require(renderer.uiImage))
            try await Task.sleep(for: .milliseconds(330))
        }
        let size = frames[0].size
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height * 6)).image { _ in
            for (i, f) in frames.enumerated() { f.draw(at: CGPoint(x: 0, y: size.height * CGFloat(i))) }
        }
        let url = URL.temporaryDirectory.appending(path: "shimmer.png")
        try #require(sheet.pngData()).write(to: url)
        print("Shimmer render: \(url.path)")
    }
}

@MainActor
struct FlowingFillCurveTests {
    @Test func fastForSixtyPercentThenSlows() {
        let f = RouteLine.fastThenSlow
        #expect(f(0) == 0 && abs(f(1) - 1) < 1e-9)
        #expect(abs(f(0.3) - 0.6) < 1e-9) // 60% of the way in 30% of the time
        let steps = stride(from: 0.0, through: 1.0, by: 0.05).map(f)
        let speeds = zip(steps, steps.dropFirst()).map { $1 - $0 }
        // Fast and steady at first, then always slowing.
        #expect(abs(speeds[0] - speeds[4]) < 1e-9)
        #expect(zip(speeds[6...], speeds[7...]).allSatisfy { $0 > $1 })
        // No jolt: just after the switch it's still going about as fast.
        #expect(abs((f(0.31) - f(0.3)) - (f(0.3) - f(0.29))) < 0.01)
    }
}
