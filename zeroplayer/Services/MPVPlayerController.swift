import UIKit
import Libmpv

// MARK: - Metal Layer (sublayer approach, matches MPVKit Demo)

/// CAMetalLayer subclass used as a sublayer of the player view controller's
/// root view. This follows the MPVKit Demo pattern for proper rotation
/// handling — the layer frame is explicitly updated in `viewDidLayoutSubviews`,
/// which triggers MoltenVK to recreate the Vulkan swapchain at the new size.
///
/// Includes a guard against MoltenVK's 1x1 drawableSize workaround that
/// can cause flicker. See: https://github.com/mpv-player/mpv/pull/13651
class MetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            // MoltenVK sometimes sets drawableSize to 1x1 to force-complete
            // a presentation. Filter these bogus values to prevent flicker.
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

// MARK: - Subtitle Track Info

/// Subtitle track discovered by mpv from the loaded file
struct MPVSubtitleTrack: Identifiable, Hashable {
    let id: Int
    let title: String?
    let lang: String?
    let isExternal: Bool
    
    var displayName: String {
        var name = title ?? "Track \(id)"
        if let lang, !lang.isEmpty {
            name += " (\(lang))"
        }
        if isExternal {
            name += " [External]"
        }
        return name
    }
}

// MARK: - MPVPlayerController

/// UIViewController that wraps libmpv with Metal rendering via MoltenVK.
/// Manages the mpv lifecycle, event loop, and exposes playback controls.
///
/// This class is `nonisolated` because mpv callbacks fire on background queues.
/// All UI updates are dispatched to the main thread via `onPropertyChange`.
nonisolated final class MPVPlayerController: UIViewController {
    
    // mpv handle
    private var mpv: OpaquePointer?
    private var metalLayer = MetalLayer()
    private let queue = DispatchQueue(label: "com.zeroplayer.mpv", qos: .userInitiated)
    
    // Track the last known layer size to detect actual resize events
    private var lastLayerSize: CGSize = .zero
    private var vidReinitWorkItem: DispatchWorkItem?
    
    // Callbacks for SwiftUI integration
    var onPropertyChange: ((_ property: String, _ value: Any?) -> Void)?
    var onSubtitleTracksDiscovered: ((_ tracks: [MPVSubtitleTrack]) -> Void)?
    var onFileLoaded: (() -> Void)?
    var onFileEnded: (() -> Void)?
    
    // File to load on viewDidLoad
    var fileURL: URL?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // Add Metal layer as a sublayer (matches MPVKit Demo pattern).
        // The layer frame is explicitly updated in viewDidLayoutSubviews
        // to ensure MoltenVK recreates the Vulkan swapchain on rotation.
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        
        setupMPV()
        setupNotifications()
        
        // Load file if one was set before viewDidLoad
        if let url = fileURL {
            loadFile(url)
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        let newSize = view.bounds.size
        metalLayer.frame = view.bounds
        
        // Detect actual size changes (e.g., rotation). mpv has no iOS vulkan
        // context backend, so its internal vo->dwidth/dheight are never updated
        // when the CAMetalLayer resizes. MoltenVK recreates the Vulkan swapchain
        // at the new size, but mpv still renders at the old dimensions.
        //
        // Workaround: toggle vid off→on to force a full VO pipeline reinit.
        // mpv re-reads the layer dimensions during reconfig.
        // Debounced so we only reinit once after the rotation animation settles.
        if lastLayerSize != .zero && newSize != lastLayerSize && mpv != nil {
            vidReinitWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.forceVOReinit()
            }
            vidReinitWorkItem = workItem
            // Fire as soon as layout settles — rotation animation calls
            // viewDidLayoutSubviews many times, the debounce collapses them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
        lastLayerSize = newSize
    }
    
    /// Forces mpv to reinitialize its video output pipeline by toggling the
    /// video track off and back on. Both property sets are synchronous on the
    /// VO thread — no intermediate delay needed.
    private func forceVOReinit() {
        guard let mpv else { return }
        print("MPV: Forcing VO reinit for resize (\(lastLayerSize))")
        let wasPaused = getFlag("pause")
        // vid=no tears down the Vulkan pipeline; vid=auto rebuilds it,
        // picking up the current CAMetalLayer dimensions via reconfig().
        mpv_set_property_string(mpv, "vid", "no")
        mpv_set_property_string(mpv, "vid", "auto")
        if !wasPaused {
            setFlag("pause", false)
        }
    }
    
    // MARK: - MPV Setup
    
    private func setupMPV() {
        // Silence MoltenVK informational logs like "[mvk-info] Destroyed VkDevice..."
        setenv("MVK_CONFIG_LOG_LEVEL", "0", 1)

        mpv = mpv_create()
        guard let mpv else {
            print("MPV: failed to create context")
            return
        }
        
        // Logging
        #if DEBUG
        checkError(mpv_request_log_messages(mpv, "warn"))
        #else
        checkError(mpv_request_log_messages(mpv, "no"))
        #endif
        
        // Pass the Metal layer (sublayer) as the render target
        var layerPtr = metalLayer
        checkError(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layerPtr))
        
        // Rendering pipeline: Metal via MoltenVK
        checkError(mpv_set_option_string(mpv, "vo", "gpu-next"))
        checkError(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        
        // Hardware decoding
        checkError(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        
        // Subtitle defaults
        checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
        checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"))
        
        // Misc
        checkError(mpv_set_option_string(mpv, "video-rotate", "no"))
        // Note: ytdl option was removed in mpv v0.41.0, do not set it
        checkError(mpv_set_option_string(mpv, "keep-open", "yes"))
        
        // Initialize
        checkError(mpv_initialize(mpv))
        
        // Observe properties for reactive updates
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)
        
        // Set wakeup callback for event processing
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let controller = Unmanaged<MPVPlayerController>.fromOpaque(ctx).takeUnretainedValue()
            controller.readEvents()
        }, pointer)
    }
    
    // MARK: - Background/Foreground Lifecycle
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    
    @objc private func didEnterBackground() {
        pause()
        if let mpv {
            checkError(mpv_set_option_string(mpv, "vid", "no"))
        }
    }
    
    @objc private func willEnterForeground() {
        if let mpv {
            checkError(mpv_set_option_string(mpv, "vid", "auto"))
        }
        play()
    }
    
    // MARK: - Event Loop
    
    private func readEvents() {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            
            while true {
                let event = mpv_wait_event(mpv, 0)
                guard let event else { break }
                
                if event.pointee.event_id == MPV_EVENT_NONE {
                    break
                }
                
                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    if let dataPtr = OpaquePointer(event.pointee.data) {
                        let property = UnsafePointer<mpv_event_property>(dataPtr).pointee
                        let name = String(cString: property.name)
                        self.handlePropertyChange(name, property)
                    }
                    
                case MPV_EVENT_FILE_LOADED:
                    print("MPV: File loaded")
                    self.discoverSubtitleTracks()
                    DispatchQueue.main.async {
                        self.onFileLoaded?()
                    }
                    
                case MPV_EVENT_END_FILE:
                    print("MPV: File ended")
                    DispatchQueue.main.async {
                        self.onFileEnded?()
                    }
                    
                case MPV_EVENT_SHUTDOWN:
                    print("MPV: Shutdown")
                    mpv_terminate_destroy(mpv)
                    self.mpv = nil
                    return
                    
                case MPV_EVENT_LOG_MESSAGE:
                    if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                        let prefix = String(cString: msg.pointee.prefix!)
                        let level = String(cString: msg.pointee.level!)
                        let text = String(cString: msg.pointee.text!)
                        print("MPV [\(prefix)] \(level): \(text)", terminator: "")
                    }
                    
                default:
                    break
                }
            }
        }
    }
    
    private func handlePropertyChange(_ name: String, _ property: mpv_event_property) {
        var value: Any?
        
        switch property.format {
        case MPV_FORMAT_DOUBLE:
            if let ptr = property.data {
                value = ptr.assumingMemoryBound(to: Double.self).pointee
            }
        case MPV_FORMAT_FLAG:
            if let ptr = property.data {
                value = ptr.assumingMemoryBound(to: Int.self).pointee != 0
            }
        case MPV_FORMAT_INT64:
            if let ptr = property.data {
                value = ptr.assumingMemoryBound(to: Int64.self).pointee
            }
        case MPV_FORMAT_STRING:
            if let ptr = property.data {
                let cstr = ptr.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                value = cstr.map { String(cString: $0) }
            }
        default:
            break
        }
        
        // Track list changes — re-discover subtitle tracks
        if name == "track-list/count" {
            discoverSubtitleTracks()
        }
        
        DispatchQueue.main.async {
            self.onPropertyChange?(name, value)
        }
    }
    
    // MARK: - Subtitle Track Discovery
    
    private func discoverSubtitleTracks() {
        guard let mpv else { return }
        
        var countVal = Int64(0)
        mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &countVal)
        let count = Int(countVal)
        
        var tracks: [MPVSubtitleTrack] = []
        
        for i in 0..<count {
            let typeStr = getString("track-list/\(i)/type")
            guard typeStr == "sub" else { continue }
            
            var idVal = Int64(0)
            mpv_get_property(mpv, "track-list/\(i)/id", MPV_FORMAT_INT64, &idVal)
            let title = getString("track-list/\(i)/title")
            let lang = getString("track-list/\(i)/lang")
            
            var externalVal = Int64(0)
            mpv_get_property(mpv, "track-list/\(i)/external", MPV_FORMAT_FLAG, &externalVal)
            
            tracks.append(MPVSubtitleTrack(
                id: Int(idVal),
                title: title,
                lang: lang,
                isExternal: externalVal != 0
            ))
        }
        
        print("MPV: Discovered \(tracks.count) subtitle track(s)")
        DispatchQueue.main.async {
            self.onSubtitleTracksDiscovered?(tracks)
        }
    }
    
    // MARK: - Playback Controls
    
    func loadFile(_ url: URL) {
        command("loadfile", args: [url.path, "replace"])
    }
    
    func play() {
        setFlag("pause", false)
    }
    
    func pause() {
        setFlag("pause", true)
    }
    
    func togglePause() {
        let paused = getFlag("pause")
        setFlag("pause", !paused)
    }
    
    func seek(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute+keyframes"])
    }
    
    func seekExact(to seconds: Double) {
        command("seek", args: [String(seconds), "absolute+exact"])
    }
    
    func seekRelative(_ seconds: Double) {
        command("seek", args: [String(seconds), "relative"])
    }
    
    var currentTime: Double {
        getDouble("time-pos")
    }
    
    var duration: Double {
        getDouble("duration")
    }
    
    var isPaused: Bool {
        getFlag("pause")
    }
    
    // MARK: - Subtitle Controls
    
    func selectSubtitleTrack(_ trackId: Int) {
        guard let mpv else { return }
        var val = Int64(trackId)
        mpv_set_property(mpv, "sid", MPV_FORMAT_INT64, &val)
        print("MPV: Selected subtitle track \(trackId)")
    }
    
    func disableSubtitles() {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "sid", "no")
        print("MPV: Subtitles disabled")
    }
    
    func addExternalSubtitle(_ path: String) {
        command("sub-add", args: [path, "select"])
        print("MPV: Added external subtitle: \(path)")
    }
    
    // MARK: - Video Track Controls (for AirPlay resource management)
    
    /// Toggles between fit (letterboxed) and fill (cropped) display modes.
    /// Uses mpv's `panscan` property: 0.0 = fit, 1.0 = fill.
    func setFillScreen(_ fill: Bool) {
        guard let mpv else { return }
        var val = fill ? 1.0 : 0.0
        mpv_set_property(mpv, "panscan", MPV_FORMAT_DOUBLE, &val)
        print("MPV: panscan = \(val) (\(fill ? "fill" : "fit"))")
    }
    
    /// Disables video decoding/rendering to free GPU resources during AirPlay.
    /// Pauses rendering first and waits for in-flight Metal/MoltenVK command buffers
    /// to complete before tearing down the video pipeline.
    func disableVideoTrack() {
        guard let mpv else { return }
        // 1. Ensure mpv is paused so no new frames are submitted
        var paused = 1
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
        // 2. Wait for in-flight GPU command buffers to drain.
        //    MoltenVK's command buffers reference textures that mpv will destroy
        //    when vid=no tears down the Vulkan rendering pipeline. Without this
        //    delay, Metal API Validation asserts on texture-still-in-use.
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let mpv = self.mpv else { return }
            mpv_set_property_string(mpv, "vid", "no")
            print("MPV: Video track disabled (AirPlay active)")
        }
    }
    
    /// Re-enables video decoding/rendering when returning from AirPlay.
    func enableVideoTrack() {
        guard let mpv else { return }
        mpv_set_property_string(mpv, "vid", "auto")
        print("MPV: Video track re-enabled")
    }
    
    // MARK: - C API Helpers
    
    private func command(_ cmd: String, args: [String] = []) {
        guard let mpv else { return }
        var allArgs: [String?] = [cmd] + args + [nil]
        let cStrings = allArgs.map { $0.flatMap { strdup($0) } }
        defer { cStrings.forEach { $0.map { free($0) } } }
        var ptrs = cStrings.map { $0.map { UnsafePointer($0) } }
        mpv_command(mpv, &ptrs)
    }
    
    private func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0 }
        var data = Double(0)
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }
    
    private func getString(_ name: String) -> String? {
        guard let mpv else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        let str = cstr.map { String(cString: $0) }
        mpv_free(cstr)
        return str
    }
    
    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var data = Int(0)
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data != 0
    }
    
    private func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }
    
    private func checkError(_ status: CInt) {
        if status < 0 {
            print("MPV error: \(String(cString: mpv_error_string(status)))")
        }
    }
    
    // MARK: - Cleanup
    
    func shutdown() {
        if let mpv {
            mpv_set_wakeup_callback(mpv, nil, nil)
            let localMpv = mpv
            self.mpv = nil
            queue.sync {
                mpv_terminate_destroy(localMpv)
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        shutdown()
    }
}
