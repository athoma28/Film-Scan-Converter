final class SendableMutableBuffer<Element>: @unchecked Sendable {
  let baseAddress: UnsafeMutablePointer<Element>

  init(_ baseAddress: UnsafeMutablePointer<Element>) {
    self.baseAddress = baseAddress
  }
}
