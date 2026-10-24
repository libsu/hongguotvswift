// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

@main struct ModelSmoke {
    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = LocalLibrary(file: directory.appendingPathComponent("library.json"))
        let model = Model(resourcesURL: resources, library: library, restoreSession: false)
        defer { model.shutdown() }
        func wait(_ predicate: @escaping @MainActor () -> Bool, seconds: Int = 90) async throws {
            for _ in 0..<(seconds * 10) {
                if predicate() { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw NSError(domain: "MacSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: \(model.message)"])
        }
        try await wait({ !model.busy })
        model.query = "大佬"; model.search()
        try await wait({ !model.busy })
        guard let series = model.rows.first else { fatalError("Search failed") }
        model.open(series)
        try await wait({ !model.busy })
        assert(model.detail != nil)
        assert(model.episode == 0, "Opening a new series must automatically start its first episode")
        model.play(0, position: 10)
        try await wait({ !model.busy })
        try await wait({ model.player.currentTime().seconds > 10.2 })
        model.player.pause(); model.saveProgress()
        guard let record = library.history(series.id), record.position >= 10 else { fatalError("Missing resume progress") }
        model.changeSpeed(1.5)
        assert(model.player.defaultRate == 1.5)
        model.changeQuality(720)
        try await wait({ !model.busy })
        assert(model.player.currentTime().seconds >= 10)
        assert(model.player.rate == 0)
        model.autoNext = true
        let duration = model.player.currentItem!.duration.seconds
        guard duration.isFinite && duration > 2 else { fatalError("Missing duration") }
        _ = await model.player.seek(to: CMTime(seconds: duration - 0.3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.player.playImmediately(atRate: 1.5)
        try await wait({ model.episode == 1 && !model.busy })
        assert(library.history(series.id)?.episodeIndex == 1)
        model.player.pause(); model.saveProgress()
        assert(LocalLibrary(file: directory.appendingPathComponent("library.json")).history(series.id)?.episodeIndex == 1)
        guard model.rows.count > 1 else { fatalError("Missing second trial") }
        let trial = model.rows[1]
        model.catalogRows = model.rows
        model.open(trial, trial: true)
        try await wait({ model.detail?.series.id == trial.id && model.episode == 0 && !model.busy })
        try await wait({ model.player.currentTime().seconds > 0.5 })
        model.saveProgress()
        assert(library.history(trial.id) == nil)
        model.changeQuality(480)
        try await wait({ !model.busy })
        assert(model.preview)
        model.saveProgress(); assert(library.history(trial.id) == nil)
        model.watchFull(); assert(library.history(trial.id) != nil)
        print("Model playback, paused quality switch, speed, automatic next, persistence and trial isolation: PASS")
    }
}
