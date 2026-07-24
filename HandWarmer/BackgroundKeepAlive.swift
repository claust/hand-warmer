import AVFoundation
import Foundation

/// Keeps the process running once the app leaves the screen.
///
/// A Live Activity buys visibility, not runtime — iOS still suspends us a few
/// seconds after backgrounding, and suspended busy loops warm nothing. The one
/// mechanism that keeps an ordinary app scheduled indefinitely is the `audio`
/// background mode with audio actually playing, so we loop a buffer of literal
/// silence for as long as the warmer runs.
///
/// The samples are zeroes and the session mixes with others, so nothing is
/// heard and whatever the user is already listening to keeps playing.
final class BackgroundKeepAlive {

    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // Build the player before activating the session: a throw between
            // the two would otherwise leave us holding audio focus with nothing
            // playing, which is both rude and useless.
            let player = try AVAudioPlayer(data: Self.silence)
            player.numberOfLoops = -1
            player.volume = 1  // the samples themselves are silent

            // .playback is the only category that survives backgrounding;
            // .mixWithOthers keeps us from stopping the user's music, and
            // .duckOthers is deliberately *not* used — we are silent anyway.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            player.play()
            self.player = player
        } catch {
            // Without this the warmer simply stops when backgrounded, as it did
            // before. Nothing else depends on it, so fail quietly — but do not
            // leave a half-configured session behind.
            player = nil
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            return
        }

        // A phone call (or any other interruption) stops the player, and
        // nothing restarts it on its own — the warmer would then die at the
        // next suspend, minutes after the call ended.
        //
        // This deliberately resumes on every `.ended` interruption rather than
        // only when the system sets `.shouldResume`. That flag exists so apps
        // don't barge back in over whatever is playing now; this player is
        // silent and mixes with others, so resuming costs the user nothing,
        // while *not* resuming silently kills a running warming session.
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                try? session.setActive(true)
                self?.player?.play()
            }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    deinit { stop() }

    /// One second of 8 kHz mono silence as a WAV, built in memory so the app
    /// doesn't have to carry an audio file just to say nothing.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = sampleRate * UInt32(blockAlign)

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))  // size of the fmt chunk
        append(UInt16(1))   // PCM, uncompressed
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        data.append(Data(count: Int(dataSize)))  // all-zero samples
        return data
    }()
}
