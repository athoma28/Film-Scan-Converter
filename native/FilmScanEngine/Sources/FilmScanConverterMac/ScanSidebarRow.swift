import AppKit
import Foundation
import SwiftUI

struct ScanSidebarRow: View {
  struct StackBadgeData: Equatable, Sendable {
    let memberCount: Int
    let isEnabled: Bool
  }

  let url: URL
  let thumbnail: NSImage?
  let isThumbnailLoading: Bool
  let isCurrentLoadingOrRendering: Bool
  let isActiveExport: Bool
  let isPendingExport: Bool
  let hasCachedPreview: Bool
  let hasEdits: Bool
  let stackBadge: StackBadgeData?

  init(
    url: URL,
    thumbnail: NSImage?,
    isThumbnailLoading: Bool,
    isCurrentLoadingOrRendering: Bool,
    isActiveExport: Bool,
    isPendingExport: Bool,
    hasCachedPreview: Bool,
    hasEdits: Bool,
    stackBadge: StackBadgeData? = nil
  ) {
    self.url = url
    self.thumbnail = thumbnail
    self.isThumbnailLoading = isThumbnailLoading
    self.isCurrentLoadingOrRendering = isCurrentLoadingOrRendering
    self.isActiveExport = isActiveExport
    self.isPendingExport = isPendingExport
    self.hasCachedPreview = hasCachedPreview
    self.hasEdits = hasEdits
    self.stackBadge = stackBadge
  }

  var body: some View {
    HStack(spacing: 10) {
      thumbnailView

      VStack(alignment: .leading, spacing: 7) {
        Text(url.lastPathComponent)
          .font(.callout)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)

        statusBadges
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }

  private var thumbnailView: some View {
    ZStack(alignment: .topTrailing) {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.secondary.opacity(0.11))

        if let thumbnail {
          // Draw the inverted sRGB bitmap through AppKit. Image(decorative:)
          // on DeviceRGB thumbnails swapped red/blue and undid the invert.
          Image(nsImage: thumbnail)
            .renderingMode(.original)
            .resizable()
            .interpolation(.medium)
            .scaledToFill()
            .frame(width: 88, height: 66)
            .clipped()
            .accessibilityHidden(true)
        } else {
          Image(systemName: "photo")
            .font(.title3)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }

        if isThumbnailLoading {
          Color.black.opacity(thumbnail == nil ? 0.12 : 0.32)
          ProgressView()
            .controlSize(.small)
            .tint(thumbnail == nil ? Color.secondary : Color.white)
            .accessibilityLabel("Loading thumbnail")
        }
      }
      .frame(width: 88, height: 66)
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(Color.primary.opacity(0.1), lineWidth: 1)
      }

      if let stackBadge {
        StackBadge(data: stackBadge)
          .padding(5)
      }
    }
    .frame(width: 88, height: 66)
  }

  @ViewBuilder
  private var statusBadges: some View {
    HStack(spacing: 4) {
      if isCurrentLoadingOrRendering {
        ProcessingBadge()
      }

      if isActiveExport {
        StatusBadge(
          systemImage: "square.and.arrow.up",
          label: "Exporting",
          tint: .accentColor)
      } else if isPendingExport {
        StatusBadge(
          systemImage: "clock",
          label: "Waiting to export",
          tint: .secondary)
      }

      if hasCachedPreview {
        StatusBadge(
          systemImage: "bolt.fill",
          label: "Source preview cached",
          tint: .secondary)
      }

      if hasEdits {
        StatusBadge(
          systemImage: "slider.horizontal.3",
          label: "Edited",
          tint: .accentColor)
      }

      Spacer(minLength: 0)
    }
    .frame(minHeight: 20)
  }
}

private struct StatusBadge: View {
  let systemImage: String
  let label: String
  let tint: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(tint)
      .frame(width: 20, height: 20)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .help(label)
      .accessibilityLabel(label)
  }
}

private struct ProcessingBadge: View {
  var body: some View {
    ProgressView()
      .controlSize(.mini)
      .frame(width: 20, height: 20)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(Color.primary.opacity(0.08), lineWidth: 1)
      }
      .help("Loading or rendering current scan")
      .accessibilityLabel("Loading or rendering current scan")
  }
}

private struct StackBadge: View {
  let data: ScanSidebarRow.StackBadgeData

  private var label: String {
    data.isEnabled
      ? "Stack enabled, \(data.memberCount) scans"
      : "Stack available, \(data.memberCount) scans"
  }

  var body: some View {
    Label("\(data.memberCount)", systemImage: "square.stack.3d.up.fill")
      .labelStyle(.titleAndIcon)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(Color.primary)
      .padding(.horizontal, 6)
      .frame(height: 20)
      .background(
        Capsule()
          .fill(
            data.isEnabled
              ? Color.accentColor.opacity(0.22)
              : Color(nsColor: .controlBackgroundColor).opacity(0.92)
          )
      )
      .overlay {
        Capsule()
          .stroke(
            data.isEnabled ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.12),
            lineWidth: 1)
      }
      .help(label)
      .accessibilityLabel(label)
  }
}
