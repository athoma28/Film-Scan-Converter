import Foundation

extension UInt16Image {
  public func getThreshold(darkThreshold: Int, lightThreshold: Int) -> UInt16Image {
    precondition(channels == 3, "Threshold generation requires a 3-channel BGR image")

    let dt = Int(Int64(darkThreshold) * 255 / 100)
    let lt = Int(Int64(lightThreshold) * 255 / 100)
    let lowerBound = dt + 1

    var binary = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let base = (y * width + x) * 3
        let b = pixels[base]
        let g = pixels[base + 1]
        let r = pixels[base + 2]
        let gray = bgrToGray(b: b, g: g, r: r)
        if gray >= lowerBound && gray <= lt {
          binary[y * width + x] = 255
        }
      }
    }

    let eroded = erode(binary: binary, width: width, height: height, kernelSize: 7, iterations: 2)
    return UInt16Image(width: width, height: height, channels: 1, pixels: eroded)
  }
}

private func convertScaleAbs16To8(_ value: UInt16) -> Int {
  (Int(value) + 128) / 257
}

private func bgrToGray(b: UInt16, g: UInt16, r: UInt16) -> Int {
  let b8 = convertScaleAbs16To8(b)
  let g8 = convertScaleAbs16To8(g)
  let r8 = convertScaleAbs16To8(r)
  return (1868 * b8 + 9617 * g8 + 4899 * r8 + 8192) >> 14
}

private func erode(
  binary: [UInt16],
  width: Int,
  height: Int,
  kernelSize: Int,
  iterations: Int
) -> [UInt16] {
  var current = binary
  let half = kernelSize / 2

  for _ in 0..<iterations {
    var next = [UInt16](repeating: 0, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        var allForeground = true
        for ky in -half...half {
          for kx in -half...half {
            let ny = y + ky
            let nx = x + kx
            if ny >= 0, ny < height, nx >= 0, nx < width {
              if current[ny * width + nx] == 0 {
                allForeground = false
                break
              }
            }
          }
          if !allForeground {
            break
          }
        }
        if allForeground {
          next[y * width + x] = 255
        }
      }
    }
    current = next
  }

  return current
}
