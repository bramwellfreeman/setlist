import Foundation

/// A single audio file in a playlist, with per-track gain, trim, and analysis.
struct Track: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var path: String                     // absolute file path
    var title: String
    var artist: String = ""
    var duration: Double = 0             // full file length, seconds
    var gainDB: Double = 0               // manual trim (user), dB
    var normalizationGainDB: Double = 0  // computed to hit the playlist target, dB
    var integratedLUFS: Double? = nil    // measured integrated loudness
    var trimStart: Double = 0            // seconds
    var trimEnd: Double = 0              // seconds; <= 0 means "end of file"
    var skip: Bool = false               // excluded from the queue
    var notes: String = ""               // cue note for this track
    /// For tracks imported from a video: the original video. `path` then points
    /// at the soundtrack extracted from it.
    var videoPath: String? = nil

    var url: URL { URL(fileURLWithPath: path) }

    var effectiveEnd: Double {
        let end = (trimEnd <= 0) ? duration : trimEnd
        return min(max(end, 0), duration > 0 ? duration : end)
    }
    var playableDuration: Double { max(0, effectiveEnd - trimStart) }

    var displayTitle: String {
        title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
    }
    var fileMissing: Bool { !FileManager.default.fileExists(atPath: path) }
    var isVideo: Bool { videoPath != nil }
    /// The file the user added (the video for video tracks).
    var sourceURL: URL { URL(fileURLWithPath: videoPath ?? path) }
    /// Nothing left to play or rebuild from: for a video track, both the
    /// extracted audio and the video are gone.
    var sourceMissing: Bool {
        guard let v = videoPath else { return fileMissing }
        return fileMissing && !FileManager.default.fileExists(atPath: v)
    }
}

// In an extension so the memberwise initializer is kept.
extension Track {
    // Decode tolerantly so libraries saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        normalizationGainDB = try c.decodeIfPresent(Double.self, forKey: .normalizationGainDB) ?? 0
        integratedLUFS = try c.decodeIfPresent(Double.self, forKey: .integratedLUFS)
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
        skip = try c.decodeIfPresent(Bool.self, forKey: .skip) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        videoPath = try c.decodeIfPresent(String.self, forKey: .videoPath)
    }
}

/// What happens when a track reaches its end.
enum ContinueMode: String, Codable, CaseIterable {
    case cue        // stop and cue the next track (default, recital-friendly)
    case gapless    // start the next track sample-accurately at the end
    case crossfade  // overlap the next track by `crossfadeSeconds`
}

/// A named, ordered collection of tracks with a loudness target.
struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var tracks: [Track] = []
    var targetLUFS: Double = -16         // match target
    var matchEnabled: Bool = false       // apply normalization gains during playback
    /// Space while playing: false = pause/resume, true = stop and cue the next track.
    var spaceStopsAndCues: Bool = false
    var notes: String = ""               // free-form show notes for this playlist
    var fadeOutSeconds: Double = 2       // fade length when stopping (0 = hard stop)
    var continueMode: ContinueMode = .cue
    var crossfadeSeconds: Double = 4
    var outputDeviceUID: String? = nil   // nil = system default output
    var outputDeviceName: String? = nil  // remembered for display if unplugged
    var parentID: UUID? = nil            // set for a sub-playlist
    var collapsed: Bool = false          // sidebar: hide this playlist's sub-playlists

    var totalDuration: Double { tracks.reduce(0) { $0 + $1.playableDuration } }

    init(id: UUID = UUID(), name: String, tracks: [Track] = []) {
        self.id = id; self.name = name; self.tracks = tracks
    }

    // Decode tolerantly so libraries saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS) ?? -16
        matchEnabled = try c.decodeIfPresent(Bool.self, forKey: .matchEnabled) ?? false
        spaceStopsAndCues = try c.decodeIfPresent(Bool.self, forKey: .spaceStopsAndCues) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds) ?? 2
        continueMode = (try? c.decodeIfPresent(ContinueMode.self, forKey: .continueMode)) ?? .cue
        crossfadeSeconds = try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds) ?? 4
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        outputDeviceName = try c.decodeIfPresent(String.self, forKey: .outputDeviceName)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }
}
