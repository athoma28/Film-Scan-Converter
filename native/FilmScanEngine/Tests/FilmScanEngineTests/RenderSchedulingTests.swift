import FilmScanEngine
import Foundation
import Testing

@Suite("Render scheduling contracts")
struct RenderSchedulingTests {

  private actor MockRenderScheduler {
    private var pending: ProcessingParameters?
    private var renderTask: Task<Void, Never>?
    private var generation = 0
    private var renderCount = 0
    private var lastRendered: ProcessingParameters?

    var renderedCount: Int { renderCount }
    var hasPending: Bool { pending != nil }
    var latestRendered: ProcessingParameters? { lastRendered }

    func submit(_ parameters: ProcessingParameters) async {
      pending = parameters
      guard renderTask == nil else { return }
      generation += 1
      let gen = generation
      renderTask = Task { [weak self] in
        guard let self else { return }
        await self.processQueue(generation: gen)
      }
    }

    private func processQueue(generation: Int) async {
      while !Task.isCancelled, let parameters = pending {
        pending = nil
        try? await Task.sleep(for: .milliseconds(5))
        renderCount += 1
        lastRendered = parameters
        guard !Task.isCancelled, generation == self.generation else { break }
        guard pending == nil else { continue }
      }
      guard generation == self.generation else { return }
      renderTask = nil
    }

    func cancelAll() {
      generation += 1
      renderTask?.cancel()
      renderTask = nil
      pending = nil
    }
  }

  @Test("Burst parameter changes coalesce into fewer renders than submissions")
  func burstCoalescesIntoFewerRenders() async {
    let scheduler = MockRenderScheduler()

    for i in 0..<50 {
      await scheduler.submit(
        ProcessingParameters(
          temperature: i, tint: i % 20, saturation: 100 + i % 50))
      try? await Task.sleep(for: .milliseconds(1))
    }

    try? await Task.sleep(for: .milliseconds(100))

    let count = await scheduler.renderedCount
    #expect(count > 0, "Should have rendered at least once")
    #expect(count < 40, "50 rapid submissions should coalesce into fewer than 40 renders, got \(count)")
  }

  @Test("Cancelling the render queue drops all pending work")
  func cancelDropsPendingWork() async {
    let scheduler = MockRenderScheduler()

    await scheduler.submit(ProcessingParameters(temperature: 50))
    try? await Task.sleep(for: .milliseconds(5))

    await scheduler.cancelAll()
    #expect(await !scheduler.hasPending)
  }

  @Test("Single parameter change renders exactly once")
  func singleChangeRendersOnce() async {
    let scheduler = MockRenderScheduler()

    await scheduler.submit(ProcessingParameters(temperature: 50))
    for _ in 0..<100 {
      if await scheduler.renderedCount == 1 { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let count = await scheduler.renderedCount
    #expect(count == 1, "Single parameter change should render exactly once, got \(count)")
  }

  @Test("Renderer processes only the latest pending when superseded")
  func onlyLatestPendingIsProcessed() async {
    let scheduler = MockRenderScheduler()

    await scheduler.submit(ProcessingParameters(temperature: 10))
    await scheduler.submit(ProcessingParameters(temperature: 20))
    await scheduler.submit(ProcessingParameters(temperature: 30))
    for _ in 0..<100 {
      if await scheduler.latestRendered?.temperature == 30, await !scheduler.hasPending {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let count = await scheduler.renderedCount
    #expect(count >= 1, "Should have rendered at least once")
    #expect(count <= 3, "3 submissions should produce at most 3 renders, got \(count)")
    #expect(await scheduler.latestRendered?.temperature == 30)
  }

  @Test("No unbounded render backlog after sustained rapid submissions")
  func noUnboundedBacklog() async {
    let scheduler = MockRenderScheduler()

    for i in 0..<200 {
      await scheduler.submit(
        ProcessingParameters(
          temperature: i % 100, tint: (i * 3) % 40, saturation: 100 + i % 50))
      try? await Task.sleep(for: .milliseconds(0))
    }

    try? await Task.sleep(for: .milliseconds(200))

    let count = await scheduler.renderedCount
    #expect(count > 0)
    #expect(count < 100, "200 rapid submissions should coalesce into <100 renders, got \(count)")
    #expect(await !scheduler.hasPending, "No pending work should remain after idle period")
  }
}
