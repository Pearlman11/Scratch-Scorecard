#if DEBUG
import SwiftUI
import ScorecardKit

/// Draws the parser's geometry on top of the scorecard photograph.
///
/// The single most useful debugging artefact for this product. A column boundary that has drifted half a
/// cell, or a row that swallowed the line below it, is invisible in a list of numbers and unmistakable when
/// drawn over the card.
struct DebugOverlayView: View {
    let image: UIImage
    let report: ParserDebugReport
    let mode: ParserDebugView.OverlayMode

    var body: some View {
        GeometryReader { proxy in
            // The image is drawn `.fit`, so the drawing area is smaller than the view on one axis. Boxes
            // are in normalized image space, so they have to be mapped into that letterboxed rect — not the
            // view's bounds, or everything lands slightly off and looks like a parser bug.
            let frame = fittedRect(imageSize: image.size, in: proxy.size)

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                Canvas { context, _ in
                    switch mode {
                    case .none:
                        break
                    case .observations:
                        drawObservations(in: context, frame: frame)
                    case .rows:
                        drawRows(in: context, frame: frame)
                    case .columns:
                        drawColumns(in: context, frame: frame)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .allowsHitTesting(false)
            }
        }
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func rect(_ cardRect: CardRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + cardRect.minX * frame.width,
            y: frame.minY + cardRect.minY * frame.height,
            width: cardRect.width * frame.width,
            height: cardRect.height * frame.height
        )
    }

    /// OCR boxes, tinted by recognition confidence so a weak read stands out.
    private func drawObservations(in context: GraphicsContext, frame: CGRect) {
        for observation in report.observations {
            let box = rect(observation.rect, in: frame)
            let tint: Color = observation.confidence >= 0.8
                ? .green
                : (observation.confidence >= 0.5 ? .yellow : .red)
            context.stroke(
                Path(roundedRect: box, cornerRadius: 1),
                with: .color(tint.opacity(0.9)),
                lineWidth: 1
            )
        }
    }

    /// Row bands, labelled with the role the classifier assigned.
    private func drawRows(in context: GraphicsContext, frame: CGRect) {
        for row in report.rows {
            let box = rect(row.rect, in: frame)
            let isPlayer = report.playerRowIndices.contains(row.index)
            let tint: Color = isPlayer ? .orange : .cyan
            context.fill(Path(box), with: .color(tint.opacity(0.14)))
            context.stroke(Path(box), with: .color(tint), lineWidth: 1)
            context.draw(
                Text(row.role)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint),
                at: CGPoint(x: box.minX + 2, y: max(frame.minY + 4, box.minY - 4)),
                anchor: .bottomLeading
            )
        }
    }

    /// Column boundaries, with interpolated columns dashed so an invented column is obvious.
    private func drawColumns(in context: GraphicsContext, frame: CGRect) {
        for column in report.columns {
            let box = CGRect(
                x: frame.minX + column.minX * frame.width,
                y: frame.minY,
                width: (column.maxX - column.minX) * frame.width,
                height: frame.height
            )
            let tint: Color = column.isInterpolated ? .red : .purple
            context.stroke(
                Path(box),
                with: .color(tint.opacity(0.75)),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: column.isInterpolated ? [3, 3] : []
                )
            )
            context.draw(
                Text(column.label)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(tint),
                at: CGPoint(x: box.midX, y: frame.minY + 6),
                anchor: .center
            )
        }
    }
}
#endif
