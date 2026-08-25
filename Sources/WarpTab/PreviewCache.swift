import AppKit
import CoreGraphics
import ScreenCaptureKit

final class PreviewCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSImage>()
    private let captureQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.warptab.preview-cache"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let stateLock = NSLock()
    private var pending: Set<String> = []
    private var cachedIdentities: Set<String> = []

    init() {
        cache.countLimit = 80
        cache.totalCostLimit = 96 * 1_024 * 1_024
    }

    func image(
        for window: WarpWindow,
        forceRefresh: Bool = false,
        refresh: @escaping (String, NSImage?) -> Void
    ) -> NSImage? {
        let cached = cache.object(forKey: window.identity as NSString)
        if cached != nil && !forceRefresh { return cached }
        guard CGPreflightScreenCaptureAccess(), let windowID = window.windowID else { return cached }

        stateLock.lock()
        let shouldCapture = pending.insert(window.identity).inserted
        stateLock.unlock()
        guard shouldCapture else { return cached }

        let identity = window.identity
        if #available(macOS 14.0, *) {
            Task { [weak self] in
                guard let self else { return }
                let source = await ModernScreenshotProvider.shared.capture(windowID: windowID, maxPixelSize: 720)
                let thumbnail = source.flatMap { self.downsample($0, maxPixelSize: 720) }
                DispatchQueue.main.async {
                    self.finishCapture(identity: identity, thumbnail: thumbnail, refresh: refresh)
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
                    self.finishCapture(identity: identity, thumbnail: thumbnail, refresh: refresh)
                }
            }
        }
        return cached
    }

    func invalidate(_ identity: String) {
        cache.removeObject(forKey: identity as NSString)
        stateLock.lock()
        cachedIdentities.remove(identity)
        stateLock.unlock()
    }

    func retainOnly(_ identities: Set<String>) {
        stateLock.lock()
        pending = pending.intersection(identities)
        let removed = cachedIdentities.subtracting(identities)
        cachedIdentities.formIntersection(identities)
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
        stateLock.unlock()
    }

    private func finishCapture(
        identity: String,
        thumbnail: NSImage?,
        refresh: @escaping (String, NSImage?) -> Void
    ) {
        precondition(Thread.isMainThread)
        stateLock.lock()
        pending.remove(identity)
        stateLock.unlock()
        if let thumbnail {
            let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
            cache.setObject(thumbnail, forKey: identity as NSString, cost: cost)
            stateLock.lock()
            cachedIdentities.insert(identity)
            stateLock.unlock()
        }
        refresh(identity, thumbnail)
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

    func capture(windowID: CGWindowID, maxPixelSize: CGFloat) async -> CGImage? {
        await acquireCaptureSlot()
        let image: CGImage?
        do {
            let content = try await shareableContent()
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                releaseCaptureSlot()
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let frame = window.frame
            let scale = min(1, maxPixelSize / max(frame.width, frame.height))
            configuration.width = max(1, Int(frame.width * scale))
            configuration.height = max(1, Int(frame.height * scale))
            configuration.showsCursor = false
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            image = nil
            catalog = nil
            catalogDate = .distantPast
        }
        releaseCaptureSlot()
        return image
    }

    private func shareableContent() async throws -> SCShareableContent {
        if let catalog, Date().timeIntervalSince(catalogDate) < 2 { return catalog }
        if let catalogTask { return try await catalogTask.value }
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
