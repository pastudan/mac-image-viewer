import AppKit
import CanvasCore
import SwiftUI
import UniformTypeIdentifiers

/// The left-hand strip: every image and video in a chosen folder and its subfolders,
/// grouped by subfolder. Scrolls vertically. Drag an item onto the canvas to add it there,
/// or double-click to add it.
struct StripView: View {
    @Bindable var strip: MediaStrip
    let model: CanvasModel

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 150), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Self.background)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { strip.chooseFolder() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(strip.folder?.lastPathComponent ?? "Choose Folder…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(strip.folder?.path ?? "Choose a folder to show in the strip")
            if strip.folder != nil {
                if strip.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { strip.rescan() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Rescan folder")
                }
            }
            Button {
                withAnimation(.easeOut(duration: 0.18)) { strip.isVisible = false }
            } label: {
                Image(systemName: "chevron.left.2")
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide strip (Control-Command-S)")
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if strip.folder == nil {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No folder").font(.headline)
                Text("Choose a folder to list its images and videos here, including subfolders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Choose Folder…") { strip.chooseFolder() }
                if LastView.shared.rememberedStripFolder != nil {
                    Button {
                        Task { await LastView.shared.restoreStripFolder() }
                    } label: {
                        Label("Restore Last Folder", systemImage: "touchid")
                    }
                    .help("Reopens the folder you used last time, after \(AppLock.methodName).")
                    .disabled(LastView.shared.isRestoring)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = strip.result, result.count > 0 {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(result.sections) { section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(section.items) { item in
                                    StripCell(item: item, model: model)
                                }
                            }
                            .padding(.horizontal, 8)
                        } header: {
                            sectionHeader(section, rootName: result.root.lastPathComponent)
                        }
                    }
                    footer(result)
                }
                .padding(.bottom, 10)
            }
        } else if strip.isScanning {
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState(icon: "photo.on.rectangle", title: "Nothing here",
                       detail: "This folder has no images or videos.",
                       action: ("Choose Another…", { strip.chooseFolder() }))
        }
    }

    private func sectionHeader(_ section: ScannedSection, rootName: String) -> some View {
        HStack {
            Text(section.relativeFolder.isEmpty ? rootName : section.relativeFolder)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Text("\(section.items.count)").foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(StripView.background.opacity(0.96))
    }

    static let background = Color(nsColor: NSColor(white: 0.12, alpha: 1))

    private func footer(_ result: FolderScanResult) -> some View {
        Text(summary(result))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private func summary(_ result: FolderScanResult) -> String {
        var parts = ["\(result.imageCount) image\(result.imageCount == 1 ? "" : "s")"]
        if result.videoCount > 0 { parts.append("\(result.videoCount) video\(result.videoCount == 1 ? "" : "s")") }
        var text = parts.joined(separator: ", ")
        if result.truncated { text += " (first \(FolderScanner.defaultLimit) shown)" }
        return text
    }

    private func emptyState(icon: String, title: String, detail: String,
                            action: (String, () -> Void)) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action.0, action: action.1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The thin bar between the strip and the canvas; drag it to resize the strip.
struct StripResizeHandle: View {
    @Bindable var strip: MediaStrip
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .frame(width: 5)
            .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1))
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = strip.width }
                        strip.width = (startWidth ?? strip.width) + value.translation.width
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// One thumbnail. Dragging it carries the file URL, which the canvas's drop handling
/// (the same one used for Finder drags) places wherever it's dropped.
struct StripCell: View {
    let item: ScannedMedia
    let model: CanvasModel

    @State private var image: NSImage?
    @State private var hovering = false
    @Environment(\.displayScale) private var displayScale

    private static let thumbSide: CGFloat = 160

    /// What a strip drag carries: the file itself, exactly like dragging it out of Finder.
    static func dragProvider(for url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }

    var body: some View {
        // A fixed square cell; the thumbnail fills it and is cropped, never overflowing.
        Color.black.opacity(0.35)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.isVideo ? "film" : "photo")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white.opacity(hovering ? 0.5 : 0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(item.relativeFolder.isEmpty ? item.name : "\(item.relativeFolder)/\(item.name)")
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.add(urls: [item.url]) }
        .onDrag {
            StripCell.dragProvider(for: item.url)
        } preview: {
            dragPreview
        }
        .contextMenu {
            Button("Add to Canvas") { model.add(urls: [item.url]) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .task(id: item.url) {
            image = ThumbnailCache.shared.cached(item.url)
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(for: item.url, side: Self.thumbSide, scale: displayScale)
            }
        }
    }

    private var dragPreview: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.isVideo ? "film" : "photo").font(.largeTitle)
            }
        }
        .frame(width: 96, height: 96)
    }
}
