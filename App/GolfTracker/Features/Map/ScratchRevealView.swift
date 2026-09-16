import SwiftUI

/// A scratch-off overlay: drag across it to reveal what is underneath.
///
/// Progress is tracked on a coarse boolean grid rather than by measuring the drawn path. Two reasons: a
/// path-area calculation is expensive to run on every touch move, and — more importantly — a grid measures
/// *coverage*, so scribbling back and forth over one corner never reaches the threshold. The golfer has to
/// actually clear the panel, which is what makes it feel like scratching rather than tapping.
struct ScratchRevealView<Content: View, Cover: View>: View {

    /// Fraction of the panel that must be cleared before the reveal completes.
    var completionThreshold: Double = 0.55
    /// Brush radius as a fraction of the panel's smaller side.
    var brushRadius: CGFloat = 0.10
    /// Declaration order matters: call sites use multiple trailing closures, which must be supplied in
    /// the order the memberwise initialiser declares them.
    @ViewBuilder var content: () -> Content
    @ViewBuilder var cover: () -> Cover
    var onComplete: () -> Void

    @State private var strokes: [Stroke] = []
    @State private var cleared = Set<GridCell>()
    @State private var hasCompleted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 24 x 16 is fine enough that partial scratching reads honestly, coarse enough to stay free.
    private let columns = 24
    private let rows = 16

    private struct GridCell: Hashable {
        let column: Int
        let row: Int
    }

    private struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint]
    }

    private var progress: Double {
        Double(cleared.count) / Double(columns * rows)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content()

                if !hasCompleted {
                    cover()
                        .mask(
                            // The mask keeps everything *except* where the golfer has scratched.
                            Canvas { context, size in
                                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                                context.blendMode = .destinationOut
                                let radius = min(size.width, size.height) * brushRadius
                                for stroke in strokes {
                                    var path = Path()
                                    guard let first = stroke.points.first else { continue }
                                    path.move(to: first)
                                    for point in stroke.points.dropFirst() {
                                        path.addLine(to: point)
                                    }
                                    context.stroke(
                                        path,
                                        with: .color(.white),
                                        style: StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round)
                                    )
                                    // A single tap leaves a dot rather than nothing.
                                    if stroke.points.count == 1 {
                                        context.fill(
                                            Path(ellipseIn: CGRect(
                                                x: first.x - radius,
                                                y: first.y - radius,
                                                width: radius * 2,
                                                height: radius * 2
                                            )),
                                            with: .color(.white)
                                        )
                                    }
                                }
                            }
                        )
                        .transition(.opacity)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    record(point: value.location, in: proxy.size, isNewStroke: value.translation == .zero)
                                }
                                .onEnded { _ in evaluateCompletion() }
                        )
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: hasCompleted)
        }
        .accessibilityElement()
        .accessibilityLabel("Scratch to mark as played")
        .accessibilityValue("\(Int(progress * 100)) percent revealed")
        .accessibilityHint("Double tap to reveal without scratching")
        // VoiceOver and Switch Control users cannot drag a path, so the same outcome is one activation away.
        .accessibilityAction {
            complete()
        }
    }

    private func record(point: CGPoint, in size: CGSize, isNewStroke: Bool) {
        guard !hasCompleted, size.width > 0, size.height > 0 else { return }
        if isNewStroke || strokes.isEmpty {
            strokes.append(Stroke(points: [point]))
        } else {
            strokes[strokes.count - 1].points.append(point)
        }

        // Mark every grid cell the brush covers, not just the one under the finger, so the measured
        // progress matches what the golfer can see has been cleared.
        let radius = min(size.width, size.height) * brushRadius
        let cellWidth = size.width / CGFloat(columns)
        let cellHeight = size.height / CGFloat(rows)
        let columnSpan = Int((radius / cellWidth).rounded(.up))
        let rowSpan = Int((radius / cellHeight).rounded(.up))
        let centerColumn = Int(point.x / cellWidth)
        let centerRow = Int(point.y / cellHeight)

        for column in (centerColumn - columnSpan)...(centerColumn + columnSpan) {
            for row in (centerRow - rowSpan)...(centerRow + rowSpan) {
                guard column >= 0, column < columns, row >= 0, row < rows else { continue }
                let cellCenter = CGPoint(
                    x: (CGFloat(column) + 0.5) * cellWidth,
                    y: (CGFloat(row) + 0.5) * cellHeight
                )
                let distance = hypot(cellCenter.x - point.x, cellCenter.y - point.y)
                if distance <= radius { cleared.insert(GridCell(column: column, row: row)) }
            }
        }

        // Complete mid-drag once the threshold is crossed: waiting for the finger to lift after the panel
        // is visibly clear feels broken.
        evaluateCompletion()
    }

    private func evaluateCompletion() {
        guard !hasCompleted, progress >= completionThreshold else { return }
        complete()
    }

    private func complete() {
        guard !hasCompleted else { return }
        hasCompleted = true
        onComplete()
    }
}
