import SwiftUI
import ScorecardKit

/// The golfer's untouched photograph, zoomable.
///
/// Exists so a questionable cell can be checked against the card itself. Zooming is essential rather than a
/// nicety: the cell in doubt is a few millimetres of handwriting on a card photographed whole.
struct OriginalPhotoView: View {
    let image: UIImage?
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            scale = min(max(lastScale * value, 1), 8)
                                        }
                                        .onEnded { _ in
                                            lastScale = scale
                                            if scale <= 1 { resetPan() }
                                        },
                                    DragGesture()
                                        .onChanged { value in
                                            guard scale > 1 else { return }
                                            offset = CGSize(
                                                width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height
                                            )
                                        }
                                        .onEnded { _ in lastOffset = offset }
                                )
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.snappy) {
                                    if scale > 1 {
                                        scale = 1
                                        lastScale = 1
                                        resetPan()
                                    } else {
                                        scale = 3
                                        lastScale = 3
                                    }
                                }
                            }
                    }
                    .background(Color.black)
                } else {
                    ContentUnavailableView(
                        "No photo",
                        systemImage: "photo",
                        description: Text("This round has no scorecard photograph attached.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func resetPan() {
        offset = .zero
        lastOffset = .zero
    }
}

/// Pick a Georgia course by hand.
///
/// Shown whenever identification was not confident. Courses the matcher considered plausible are surfaced
/// first, because when the parser is unsure it is usually unsure between two or three specific cards.
struct CoursePickerView: View {
    let templates: [CourseTemplate]
    let suggestedIDs: [String]
    let selectedID: String?
    let onSelect: (CourseTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var suggested: [CourseTemplate] {
        suggestedIDs.compactMap { id in templates.first { $0.id == id } }
    }

    private var filtered: [CourseTemplate] {
        guard !searchText.isEmpty else { return templates }
        let query = TextNormalizer.normalizeName(searchText)
        return templates.filter {
            TextNormalizer.normalizeName($0.identity.displayName).contains(query)
                || TextNormalizer.normalizeName($0.identity.city).contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !suggested.isEmpty && searchText.isEmpty {
                    Section("Best matches") {
                        ForEach(suggested) { template in row(template) }
                    }
                }
                Section(searchText.isEmpty ? "All Georgia courses" : "Results") {
                    ForEach(filtered) { template in row(template) }
                }
            }
            .searchable(text: $searchText, prompt: "Search Georgia courses")
            .navigationTitle("Choose Course")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ template: CourseTemplate) -> some View {
        Button {
            onSelect(template)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.identity.displayName)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(template.identity.city)
                        if template.mayRestoreStaticData {
                            Label("Card on file", systemImage: "checkmark.seal.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if template.id == selectedID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(minHeight: Theme.minimumTapTarget)
        }
        .buttonStyle(.plain)
    }
}

/// Pick the tees played. Changing this refreshes every yardage from the course's template.
struct TeePickerView: View {
    let tees: [TeeSetTemplate]
    let selected: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tees) { tee in
                        Button {
                            onSelect(tee.name)
                            dismiss()
                        } label: {
                            HStack {
                                if let colorName = tee.colorName {
                                    Circle()
                                        .fill(teeColor(colorName))
                                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                                        .frame(width: 16, height: 16)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tee.name)
                                        .foregroundStyle(.primary)
                                    if let total = tee.totalYardage {
                                        Text("\(total) yards")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if tee.name == selected {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(minHeight: Theme.minimumTapTarget)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("A scorecard prints every set of tees, so it can't say which you played. Choosing here fills in the matching yardages.")
                }
            }
            .navigationTitle("Choose Tees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func teeColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "black": return .black
        case "blue": return .blue
        case "white": return .white
        case "red": return .red
        case "gold": return .yellow
        case "green": return .green
        case "silver": return Color(white: 0.7)
        case "bronze", "copper": return .brown
        case "orange": return .orange
        case "yellow": return .yellow
        case "purple": return .purple
        case "maroon": return Color(red: 0.5, green: 0.0, blue: 0.13)
        default: return .gray
        }
    }
}
