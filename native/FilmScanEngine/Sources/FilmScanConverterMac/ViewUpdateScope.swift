import SwiftUI

/// Evaluate a section in its own body so Observation dependencies stay local.
/// An inline computed view otherwise adds its model reads to its caller, making
/// new preview rasters rebuild controls that only depend on editing parameters.
struct ViewUpdateScope<Content: View>: View {
  private let content: () -> Content

  init(@ViewBuilder content: @escaping () -> Content) {
    self.content = content
  }

  var body: some View { content() }
}
