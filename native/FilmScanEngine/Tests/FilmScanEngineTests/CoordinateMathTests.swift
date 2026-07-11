import Foundation
import Testing

@testable import FilmScanEngine

@Suite("Coordinate math")
struct CoordinateMathTests {
  @Test("shrinkBox shrinks a 0-degree rectangle inward by 5%/3%")
  func shrinkBoxZeroDegrees() {
    let box: [(Double, Double)] = [(150, 180), (150, 120), (250, 120), (250, 180)]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: 5, yPercent: 3)
    #expect(result.map { [$0.x, $0.y] } == [[153, 172], [153, 114], [247, 128], [247, 186]])
  }

  @Test("shrinkBox with 0%/0% returns the same box")
  func shrinkBoxNoChange() {
    let box: [(Double, Double)] = [(150, 180), (150, 120), (250, 120), (250, 180)]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: 0, yPercent: 0)
    #expect(result.map { [$0.x, $0.y] } == [[150, 180], [150, 120], [250, 120], [250, 180]])
  }

  @Test("shrinkBox with negative percentages expands the box")
  func shrinkBoxExpand() {
    let box: [(Double, Double)] = [(150, 180), (150, 120), (250, 120), (250, 180)]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: -2, yPercent: -2)
    #expect(result.map { [$0.x, $0.y] } == [[149, 178], [149, 116], [251, 122], [251, 184]])
  }

  @Test("shrinkBox handles a 15-degree rotated rectangle")
  func shrinkBoxRotated15Deg() {
    let box: [(Double, Double)] = [
      (143.9391326904297, 166.0368194580078),
      (159.46827697753906, 108.08126831054688),
      (256.06085205078125, 133.9631805419922),
      (240.53172302246094, 191.91873168945312),
    ]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: 5, yPercent: 3)
    #expect(result.map { [$0.x, $0.y] } == [[147, 166], [163, 110], [252, 133], [236, 189]])
  }

  @Test("shrinkBox handles a -30-degree rotated rectangle")
  func shrinkBoxRotatedMinus30Deg() {
    let box: [(Double, Double)] = [
      (171.69873046875, 200.9807586669922),
      (141.69873046875, 149.0192413330078),
      (228.30126953125, 99.01924133300781),
      (258.30126953125, 150.9807586669922),
    ]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: 5, yPercent: 3)
    #expect(result.map { [$0.x, $0.y] } == [[175, 197], [145, 148], [224, 102], [254, 151]])
  }

  @Test("shrinkBox handles a 45-degree rotated rectangle")
  func shrinkBoxRotated45Deg() {
    let box: [(Double, Double)] = [
      (43.43145751953125, 214.14215087890625),
      (114.14214324951172, 143.43145751953125),
      (156.56854248046875, 185.85784912109375),
      (85.85785675048828, 256.56854248046875),
    ]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: 5, yPercent: 3)
    #expect(result.map { [$0.x, $0.y] } == [[45, 209], [112, 148], [154, 190], [87, 251]])
  }

  @Test("shrinkBox handles a large 10-degree rotated rectangle")
  func shrinkBoxLargeRotated() {
    let box: [(Double, Double)] = [
      (334.9140319824219, 572.4335327148438),
      (369.6436462402344, 375.47198486328125),
      (665.0859375, 427.56646728515625),
      (630.3563232421875, 624.5280151367188),
    ]
    let result = CoordinateMath.shrinkBox(box: box, xPercent: 5, yPercent: 3)
    #expect(result.map { [$0.x, $0.y] } == [[349, 569], [382, 382], [650, 430], [617, 617]])
  }

  @Test("shrinkBox preserves one-pixel distinctions above Float precision")
  func shrinkBoxPreservesDoublePrecision() {
    let origin = 16_777_216.0
    let box: [(Double, Double)] = [
      (origin, 180),
      (origin, 120),
      (origin + 1, 120),
      (origin + 1, 180),
    ]

    let result = CoordinateMath.shrinkBox(box: box, xPercent: 0, yPercent: 0)

    #expect(result.map { [$0.x, $0.y] } == [
      [16_777_216, 180],
      [16_777_216, 120],
      [16_777_217, 120],
      [16_777_217, 180],
    ])
  }
}
