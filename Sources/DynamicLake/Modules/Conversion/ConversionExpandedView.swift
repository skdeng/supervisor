import SwiftUI

/// The module's section in the expanded panel: a header, the ffmpeg-missing note (when
/// applicable), a drop zone, format/quality pickers, and the active/recent conversion list.
struct ConversionExpandedView: View {
    @ObservedObject var module: ConversionModule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if module.didLocate && !module.isFFmpegAvailable {
                installNote
            }

            ConversionDropZone(module: module)
                .disabled(!module.isFFmpegAvailable)
                .opacity(module.isFFmpegAvailable ? 1 : 0.5)

            if module.isFFmpegAvailable {
                pickers
            }

            taskList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
            Text("Convert")
                .font(.headline)
            Spacer()
            if !module.recentTasks.isEmpty {
                Button("Clear") { module.clearRecent() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
    }

    // MARK: ffmpeg install note

    private var installNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text("FFmpeg not found")
                    .font(.callout.weight(.semibold))
                Text("Install it to enable conversions:")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                Text("brew install ffmpeg")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: NotchTheme.surfaceCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: Pickers

    private var pickers: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Format")
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                Picker("Format", selection: $module.selectedFormat) {
                    ForEach(TargetFormat.formats(for: module.pickerKind)) { format in
                        Text(format.label).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Quality")
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                Picker("Quality", selection: $module.selectedQuality) {
                    ForEach(ConversionQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Task list

    @ViewBuilder
    private var taskList: some View {
        let active = module.activeTasks
        let recent = module.recentTasks

        if !active.isEmpty || !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(active) { task in
                    ConversionTaskRow(task: task, module: module)
                }
                if !active.isEmpty && !recent.isEmpty {
                    Divider().background(NotchTheme.separator)
                }
                ForEach(recent) { task in
                    ConversionTaskRow(task: task, module: module)
                }
            }
        }
    }
}

/// A single conversion row: source → target name, a progress/state indicator, and a context
/// action (cancel while running, reveal-in-Finder when finished).
struct ConversionTaskRow: View {
    @ObservedObject var task: ConversionTask
    @ObservedObject var module: ConversionModule

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.job.outputName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingControl
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if case .finished = task.state { module.revealInFinder(task) }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.state {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(NotchTheme.secondaryForeground)
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(NotchTheme.primaryForeground)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle")
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        switch task.state {
        case .queued:
            label("Queued · \(task.job.format.label)")
        case let .running(fraction):
            VStack(alignment: .leading, spacing: 3) {
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(NotchTheme.primaryForeground)
                    label("\(Int(fraction * 100))% · \(task.job.format.label)")
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(NotchTheme.primaryForeground)
                    label("Converting · \(task.job.format.label)")
                }
            }
        case .finished:
            label("Done · \(task.job.format.label) · Reveal in Finder")
        case let .failed(reason):
            label(reason)
                .foregroundStyle(.red.opacity(0.9))
        case .cancelled:
            label("Cancelled")
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch task.state {
        case .queued, .running:
            Button {
                module.cancel(task)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .finished:
            Button {
                module.revealInFinder(task)
            } label: {
                Image(systemName: "magnifyingglass.circle")
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        case .failed, .cancelled:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(NotchTheme.secondaryForeground)
            .lineLimit(2)
    }
}
