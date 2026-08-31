import AppKit
import CoreGraphics
import ScreenCaptureKit

final class PreviewCache: @unchecked Sendable {
    private struct SourceKey: Equatable {
        let windowID: CGWindowID?
        let title: String
        let bounds: CGRect
        let isMinimized: Bool
        let isHidden: Bool
        let isFullscreen: Bool

        init(window: WarpWindow) {
            windowID = window.windowID
            title = window.title
            bounds = window.bounds
            isMinimized = window.isMinimized
            isHidden = window.isHidden
            isFullscreen = window.isFullscreen
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let captureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.warptab.preview-cache"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let stateLock = NSLock()
    private var pending: [String: UInt64] = [:]
    private var cachedIdentities: Set<String> = []
    private var sourceKeys: [String: SourceKey] = [:]
    private var generations: [String: UInt64] = [:]

    init() {
        cache.countLimit = 80
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func prepare() {
        guard CGPreflightScreenCaptureAccess() else { return }
        if #available(macOS 14.0, *) {
            Task { await ModernScreenshotProvider.shared.prepare() }
        }
    }

    func image(
        for window: WarpWindow,
        forceRefresh: Bool = false,
        refresh: @escaping (String, NSImage?) -> Void
    ) -> NSImage? {
        let identity = window.identity
        let sourceKey = SourceKey(window: window)
        var sourceChanged = false
        var refreshCaptureCatalog = false
        var generation: UInt64 = 0

        stateLock.lock()
        let previousSourceKey = sourceKeys[identity]
        if previousSourceKey != sourceKey {
            if let previousSourceKey {
                refreshCaptureCatalog = previousSourceKey.windowID != sourceKey.windowID ||
                    previousSourceKey.bounds != sourceKey.bounds ||
                    previousSourceKey.isMinimized != sourceKey.isMinimized ||
                    previousSourceKey.isHidden != sourceKey.isHidden ||
                    previousSourceKey.isFullscreen != sourceKey.isFullscreen
            }
            sourceKeys[identity] = sourceKey
            generations[identity, default: 0] &+= 1
            generation = generations[identity, default: 0]
            pending.removeValue(forKey: identity)
            cachedIdentities.remove(identity)
            sourceChanged = true
        } else {
            generation = generations[identity, default: 0]
        }
        stateLock.unlock()

        // A full-screen transition, native-tab change, or CG window remap can
        // keep the same AX identity while changing what should be captured.
        // Never display the previous source while its replacement is loading.
        if sourceChanged { cache.removeObject(forKey: identity as NSString) }

        let cached = cache.object(forKey: identity as NSString)
        if cached != nil && !forceRefresh { return cached }
        guard CGPreflightScreenCaptureAccess(), let windowID = window.windowID else { return cached }

        stateLock.lock()
        let shouldCapture: Bool
        if sourceKeys[identity] == sourceKey, pending[identity] == nil {
            pending[identity] = generation
            shouldCapture = true
        } else {
            shouldCapture = false
        }
        stateLock.unlock()
        guard shouldCapture else { return cached }

        if #available(macOS 14.0, *) {
            Task { [weak self] in
                guard let self else { return }
                let modernSource = await ModernScreenshotProvider.shared.capture(
                    windowID: windowID,
                    maxPixelSize: 720,
                    expectedBounds: sourceKey.bounds,
                    refreshCatalog: refreshCaptureCatalog
                )
                // ScreenCaptureKit can briefly expose the previous geometry
                // while a full-screen Space is settling. Its catalog retries
                // normally resolve that; use the exact CG window as a bounded
                // fallback instead of returning a stretched stale frame.
                let source = modernSource ?? CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowID,
                    [.boundsIgnoreFraming, .bestResolution]
                )
                let thumbnail = source.flatMap { self.downsample($0, maxPixelSize: 720) }
                DispatchQueue.main.async {
                    self.finishCapture(
                        identity: identity,
                        sourceKey: sourceKey,
                        generation: generation,
                        thumbnail: thumbnail,
                        refresh: refresh
                    )
                }
            }
        } else {
            captureQueue.addOperation { [weak self] in
                guard let self else { return }
                let source = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    windowID,
                    [.boundsIgnoreFraming, .bestResolution]
                )
                let thumbnail = source.flatMap { self.downsample($0, maxPixelSize: 720) }
                DispatchQueue.main.async {
                    self.finishCapture(
                        identity: identity,
                        sourceKey: sourceKey,
                        generation: generation,
                        thumbnail: thumbnail,
                        refresh: refresh
                    )
                }
            }
        }
        return cached
    }

    func invalidate(_ identity: String) {
        cache.removeObject(forKey: identity as NSString)
        stateLock.lock()
        cachedIdentities.remove(identity)
        sourceKeys.removeValue(forKey: identity)
        generations[identity, default: 0] &+= 1
        pending.removeValue(forKey: identity)
        stateLock.unlock()
    }

    func retainOnly(_ identities: Set<String>) {
        stateLock.lock()
        pending = pending.filter { identities.contains($0.key) }
        let removed = cachedIdentities.subtracting(identities)
        cachedIdentities.formIntersection(identities)
        sourceKeys = sourceKeys.filter { identities.contains($0.key) }
        generations = generations.filter { identities.contains($0.key) }
        stateLock.unlock()
        for identity in removed {
            cache.removeObject(forKey: identity as NSString)
        }
    }

    func purge() {
        cache.removeAllObjects()
        stateLock.lock()
        cachedIdentities.removeAll()
        pending.removeAll()
        sourceKeys.removeAll()
        generations.removeAll()
        stateLock.unlock()
    }

    private func finishCapture(
        identity: String,
        sourceKey: SourceKey,
        generation: UInt64,
        thumbnail: NSImage?,
        refresh: @escaping (String, NSImage?) -> Void
    ) {
        precondition(Thread.isMainThread)
        stateLock.lock()
        guard sourceKeys[identity] == sourceKey,
              generations[identity] == generation else {
            if pending[identity] == generation { pending.removeValue(forKey: identity) }
            stateLock.unlock()
            return
        }
        if pending[identity] == generation { pending.removeValue(forKey: identity) }
        if let thumbnail {
            let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
            cache.setObject(thumbnail, forKey: identity as NSString, cost: cost)
            cachedIdentities.insert(identity)
        }
        let displayedImage = thumbnail ?? cache.object(forKey: identity as NSString)
        stateLock.unlock()
        refresh(identity, displayedImage)
    }

    private func downsample(_ image: CGImage, maxPixelSize: CGFloat) -> NSImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxPixelSize / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: targetWidth, height: targetHeight))
    }
}

@available(macOS 14.0, *)
private actor ModernScreenshotProvider {
    static let shared = ModernScreenshotProvider()

    private var catalog: SCShareableContent?
    private var catalogDate = Date.distantPast
    private var catalogTask: Task<SCShareableContent, Error>?
    private var activeCaptures = 0
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare() async {
        _ = try? await shareableContent(forceRefresh: false)
    }

    func capture(
        windowID: CGWindowID,
        maxPixelSize: CGFloat,
        expectedBounds: CGRect,
        refreshCatalog: Bool = false
    ) async -> CGImage? {
        await acquireCaptureSlot()
        defer { releaseCaptureSlot() }

        // Entering or leaving a full-screen Space can replace the underlying
        // SCWindow before the cached catalog expires. Retry once with a fresh
        // catalog so the preview follows the new Space immediately.
        let expectedAspectRatio = expectedBounds.width / max(1, expectedBounds.height)
        for attempt in 0..<3 {
            do {
                let content = try await shareableContent(forceRefresh: refreshCatalog || attempt > 0)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    invalidateCatalog()
                    continue
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let frame = window.frame
                let sourceAspectRatio = frame.width / max(1, frame.height)
                if expectedAspectRatio.isFinite,
                   expectedAspectRatio > 0,
                   abs(log(sourceAspectRatio / expectedAspectRatio)) >= 0.06 {
                    invalidateCatalog()
                    if attempt < 2 { try? await Task.sleep(nanoseconds: 35_000_000) }
                    continue
                }
                let longestEdge = max(1, max(frame.width, frame.height))
                let scale = min(1, maxPixelSize / longestEdge)
                configuration.width = max(1, Int(frame.width * scale))
                configuration.height = max(1, Int(frame.height * scale))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                let capturedAspectRatio = CGFloat(image.width) / max(1, CGFloat(image.height))
                if expectedAspectRatio.isFinite,
                   expectedAspectRatio > 0,
                   abs(log(capturedAspectRatio / expectedAspectRatio)) >= 0.06 {
                    invalidateCatalog()
                    if attempt < 2 { try? await Task.sleep(nanoseconds: 35_000_000) }
                    continue
                }
                return image
            } catch {
                invalidateCatalog()
            }
        }
        return nil
    }

    private func shareableContent(forceRefresh: Bool) async throws -> SCShareableContent {
        if !forceRefresh, let catalog, Date().timeIntervalSince(catalogDate) < 2 { return catalog }
        if let catalogTask { return try await catalogTask.value }
        if forceRefresh { invalidateCatalog() }
        let task = Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        catalogTask = task
        do {
            let content = try await task.value
            catalog = content
            catalogDate = Date()
            catalogTask = nil
            return content
        } catch {
            catalogTask = nil
            throw error
        }
    }

    private func invalidateCatalog() {
        catalog = nil
        catalogDate = .distantPast
    }

    private func acquireCaptureSlot() async {
        if activeCaptures < 2 {
            activeCaptures += 1
            return
        }
        await withCheckedContinuation { continuation in
            captureWaiters.append(continuation)
        }
    }

    private func releaseCaptureSlot() {
        if captureWaiters.isEmpty {
            activeCaptures = max(0, activeCaptures - 1)
        } else {
            captureWaiters.removeFirst().resume()
        }
    }
}
