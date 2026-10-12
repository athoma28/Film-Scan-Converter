import FilmScanEngine
import SwiftUI

/// The owner keeps the store alive when sections or the inspector collapse, so
/// the session's performance fallback cannot restart expensive optional work.
struct PresetPreviewStrip: View {
  @Bindable var model: AppModel
  @Bindable var store: PresetPreviewStore

  var body: some View {
    let request = model.presetPreviewRequest
    let thumbnails = store.thumbnails(for: request?.key)
    VStack(alignment: .leading, spacing: 0) {
      if !thumbnails.isEmpty {
        ScrollView(.horizontal) {
          HStack(alignment: .top, spacing: 6) {
            ForEach(thumbnails) { thumbnail in
              tile(thumbnail)
            }
          }
          .padding(.vertical, 3)
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("Look previews")
      }
    }
    .onChange(of: request?.key, initial: true) {
      store.update(request)
    }
    .onDisappear {
      store.update(nil)
    }
  }

  private func tile(_ thumbnail: PresetPreviewThumbnail) -> some View {
    let isSelected = thumbnail.recipe.matches(model.parameters)
    return Button {
      model.applyLookRecipe(thumbnail.recipe)
    } label: {
      VStack(spacing: 5) {
        Image(decorative: thumbnail.image, scale: 2)
          .resizable()
          .interpolation(.medium)
          .scaledToFit()
          .frame(width: 80, height: 64)
          .background(Color.black.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        Text(thumbnail.recipe.title)
          .font(.caption2)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(width: 80, height: 27, alignment: .top)
      }
      .padding(4)
      .background(
        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .help(thumbnail.recipe.summary)
    .accessibilityLabel(thumbnail.recipe.title)
    .accessibilityValue(isSelected ? "Applied" : "")
    .accessibilityHint("Apply this look to the current scan")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
