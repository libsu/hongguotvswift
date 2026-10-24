// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CoreVideo

@main struct PlaybackSmoke {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]), url.host == "127.0.0.1" else { fatalError("Expected private local playback URL") }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        var frames = 0
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if item.status == .failed { fatalError("Native playback failed") }
            if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { frames += 1 }
            if frames >= 3 { break }
        }
        guard frames >= 3 else { fatalError("No decoded streaming frames") }
        let duration = CMTimeGetSeconds(item.duration)
        let target = min(20, duration / 2)
        guard target.isFinite, target > 0 else { fatalError("Missing duration") }
        let sought = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard sought else { fatalError("Seek failed") }
        var seekFrame = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { seekFrame = true; break }
        }
        player.pause(); player.replaceCurrentItem(with: nil)
        guard seekFrame else { fatalError("No video frame after seeking") }
        print("Native streamed video frames and seek: PASS")
    }
}
