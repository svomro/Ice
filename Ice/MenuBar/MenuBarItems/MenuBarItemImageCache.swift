//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine
import ScreenCaptureKit

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// The cached item images.
    @Published private(set) var images = [MenuBarItemInfo: CGImage]()

    /// Visible item images captured separately for each display while clear mode is active.
    ///
    /// The regular ``images`` cache intentionally follows the main screen because it is also
    /// used by Ice Bar, Search, and Layout Bar. Clear overlays exist on every screen, so they
    /// need a display-local snapshot set instead of reusing the main screen's pixels.
    @Published private(set) var clearImagesByDisplay = [CGDirectDisplayID: [CGWindowID: CGImage]]()

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The currently running cache update task.
    private var updateTask: Task<Void, Never>?

    /// Identifies the current cache update so a stale task cannot clear a newer one.
    private var updateTaskToken: UUID?

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    @MainActor
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Update every second at minimum. Clear appearance redraws native
                // status items, including clocks configured to show seconds.
                Timer.publish(every: 1, on: .main, in: .default).autoconnect().mapToVoid(),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid(),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                self?.scheduleUpdate()
            }
            .store(in: &c)

            appState.$isScreenCaptureAllowed
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isAllowed in
                    guard let self else { return }
                    if isAllowed {
                        scheduleUpdate()
                    } else {
                        cancelUpdate()
                    }
                }
                .store(in: &c)
        }

        cancellables = c
    }

    /// Starts one cache update if another one is not already in flight.
    @MainActor
    private func scheduleUpdate() {
        guard
            updateTask == nil,
            appState?.isScreenCaptureAllowed == true
        else {
            return
        }

        let token = UUID()
        updateTaskToken = token
        updateTask = Task.detached { [weak self] in
            guard let self else { return }
            if ScreenCapture.cachedCheckPermissions() {
                await self.updateCache()
            }
            await self.finishUpdate(token: token)
        }
    }

    /// Cancels the current cache update and immediately allows a fresh update later.
    @MainActor
    private func cancelUpdate() {
        updateTaskToken = nil
        updateTask?.cancel()
        updateTask = nil
    }

    /// Clears the current cache update only when it still belongs to the given token.
    @MainActor
    private func finishUpdate(token: UUID) {
        guard updateTaskToken == token else {
            return
        }
        updateTask = nil
        updateTaskToken = nil
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.imageCache.debug("Skipping menu bar item image cache as \(reason)")
    }

    /// Returns a Boolean value that indicates whether caching menu bar items failed for
    /// the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.info) {
            return false
        }
        return true
    }

    /// Captures visible menu bar item windows with ScreenCaptureKit's single-frame API.
    /// Clear mode refreshes these images frequently, so avoid the legacy continuous
    /// screen-capture indicator when the modern API is available.
    @available(macOS 14.0, *)
    private func createClearWindowImagesWithScreenCaptureKit(
        for items: [MenuBarItem],
        screen: NSScreen
    ) async -> [CGWindowID: CGImage] {
        guard
            let appState,
            await appState.isScreenCaptureAllowed,
            !Task.isCancelled
        else {
            return [:]
        }
        let displayBounds = CGDisplayBounds(screen.displayID)
        let backingScaleFactor = screen.backingScaleFactor

        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            Logger.imageCache.error("ScreenCaptureKit shareable content failed: \(error.localizedDescription)")
            return [:]
        }

        guard
            await appState.isScreenCaptureAllowed,
            !Task.isCancelled
        else {
            return [:]
        }

        let windowsByID = Dictionary(
            uniqueKeysWithValues: shareableContent.windows.map { ($0.windowID, $0) }
        )
        var images = [CGWindowID: CGImage]()

        for item in items {
            guard
                await appState.isScreenCaptureAllowed,
                !Task.isCancelled
            else {
                return images
            }

            let windowID = item.windowID
            guard
                let itemFrame = Bridging.getWindowFrame(for: windowID),
                itemFrame.minY == displayBounds.minY
            else {
                continue
            }

            if item.info.namespace == .ice {
                let image = await MainActor.run { () -> CGImage? in
                    let sectionName: MenuBarSection.Name? = switch item.info {
                    case .iceIcon: .visible
                    case .hiddenControlItem: .hidden
                    case .alwaysHiddenControlItem: .alwaysHidden
                    default: nil
                    }
                    guard
                        let sectionName,
                        let controlItem = appState.menuBarManager.section(withName: sectionName)?.controlItem
                    else {
                        return nil
                    }
                    return controlItem.renderedImage()
                }
                if let image {
                    images[windowID] = image
                }
                continue
            }

            guard let window = windowsByID[windowID] else {
                continue
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((itemFrame.width * backingScaleFactor).rounded()))
            configuration.height = max(1, Int((itemFrame.height * backingScaleFactor).rounded()))
            configuration.showsCursor = false

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                guard
                    await appState.isScreenCaptureAllowed,
                    !Task.isCancelled
                else {
                    return images
                }
                images[windowID] = image
            } catch {
                Logger.imageCache.debug(
                    "ScreenCaptureKit failed for menu bar item \(windowID): \(error.localizedDescription)"
                )
            }
        }

        return images
    }

    /// Captures clear-mode images using the legacy item-info cache key expected by Ice Bar,
    /// Search, and Layout Bar. Duplicate item infos intentionally retain the existing
    /// last-wins behavior here; clear menu bar overlays use window IDs instead.
    @available(macOS 14.0, *)
    private func createClearImagesWithScreenCaptureKit(
        for items: [MenuBarItem],
        screen: NSScreen
    ) async -> [MenuBarItemInfo: CGImage] {
        let windowImages = await createClearWindowImagesWithScreenCaptureKit(for: items, screen: screen)
        var images = [MenuBarItemInfo: CGImage]()
        for item in items {
            if let image = windowImages[item.windowID] {
                images[item.info] = image
            }
        }
        return images
    }

    /// Captures the menu bar items that are currently visible on the given screen.
    ///
    /// This is kept separate from the regular section cache because the latter also contains
    /// off-screen hidden items and is deliberately tied to the main screen. A clear overlay
    /// only needs the native items visible on the display it covers.
    @available(macOS 14.0, *)
    private func createVisibleClearImages(for screen: NSScreen) async -> [CGWindowID: CGImage]? {
        let items = MenuBarItem.getMenuBarItems(
            on: screen.displayID,
            onScreenOnly: true,
            activeSpaceOnly: false
        )
        guard !items.isEmpty else {
            return nil
        }
        let images = await createClearWindowImagesWithScreenCaptureKit(for: items, screen: screen)
        guard !images.isEmpty else {
            return nil
        }
        return images
    }

    /// Captures the images of the current menu bar items and returns a dictionary containing
    /// the images, keyed by the current menu bar item infos.
    func createImages(for section: MenuBarSection.Name, screen: NSScreen) async -> [MenuBarItemInfo: CGImage] {
        guard let appState else {
            return [:]
        }

        let items = await appState.itemManager.itemCache[section]
        let isClearAppearance = await appState.appearanceManager.configuration.shapeKind == .clear

        if isClearAppearance, #available(macOS 14.0, *) {
            return await createClearImagesWithScreenCaptureKit(for: items, screen: screen)
        }

        var images = [MenuBarItemInfo: CGImage]()
        let backingScaleFactor = screen.backingScaleFactor
        let displayBounds = CGDisplayBounds(screen.displayID)
        let option: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        let defaultItemThickness = NSStatusBar.system.thickness * backingScaleFactor

        var itemInfos = [CGWindowID: MenuBarItemInfo]()
        var itemFrames = [CGWindowID: CGRect]()
        var windowIDs = [CGWindowID]()
        var frame = CGRect.null

        for item in items {
            let windowID = item.windowID
            guard
                // Use the most up-to-date window frame.
                let itemFrame = Bridging.getWindowFrame(for: windowID),
                itemFrame.minY == displayBounds.minY
            else {
                continue
            }
            itemInfos[windowID] = item.info
            itemFrames[windowID] = itemFrame
            windowIDs.append(windowID)
            frame = frame.union(itemFrame)
        }

        if
            let compositeImage = ScreenCapture.captureWindows(windowIDs, option: option),
            CGFloat(compositeImage.width) == frame.width * backingScaleFactor
        {
            for windowID in windowIDs {
                guard
                    let itemInfo = itemInfos[windowID],
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: (itemFrame.origin.x - frame.origin.x) * backingScaleFactor,
                    y: (itemFrame.origin.y - frame.origin.y) * backingScaleFactor,
                    width: itemFrame.width * backingScaleFactor,
                    height: itemFrame.height * backingScaleFactor
                )

                guard let itemImage = compositeImage.cropping(to: frame) else {
                    continue
                }

                images[itemInfo] = itemImage
            }
        } else {
            Logger.imageCache.warning("Composite image capture failed. Attempting to capturing items individually.")

            for windowID in windowIDs {
                guard
                    let itemInfo = itemInfos[windowID],
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: 0,
                    y: ((itemFrame.height * backingScaleFactor) / 2) - (defaultItemThickness / 2),
                    width: itemFrame.width * backingScaleFactor,
                    height: defaultItemThickness
                )

                guard
                    let itemImage = ScreenCapture.captureWindow(windowID, option: option),
                    let croppedImage = itemImage.cropping(to: frame)
                else {
                    continue
                }

                images[itemInfo] = croppedImage
            }
        }

        return images
    }

    /// Updates the cache for the given sections, without checking whether caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard
            let appState,
            await appState.isScreenCaptureAllowed,
            !Task.isCancelled,
            let screen = NSScreen.main
        else {
            return
        }

        let isClearAppearance = await appState.appearanceManager.configuration.shapeKind == .clear
        if isClearAppearance, #available(macOS 14.0, *) {
            let screens = await MainActor.run { NSScreen.screens }
            let activeDisplayIDs = Set(screens.map(\.displayID))
            var imagesByDisplay = await MainActor.run {
                clearImagesByDisplay.filter { activeDisplayIDs.contains($0.key) }
            }

            for screen in screens {
                guard
                    await appState.isScreenCaptureAllowed,
                    !Task.isCancelled
                else {
                    return
                }
                if let images = await createVisibleClearImages(for: screen) {
                    var mergedImages = imagesByDisplay[screen.displayID] ?? [:]
                    mergedImages.merge(images) { _, new in new }
                    imagesByDisplay[screen.displayID] = mergedImages
                }
            }

            guard
                await appState.isScreenCaptureAllowed,
                !Task.isCancelled
            else {
                return
            }
            await MainActor.run { [imagesByDisplay] in
                clearImagesByDisplay = imagesByDisplay
            }
        } else if !clearImagesByDisplay.isEmpty {
            await MainActor.run {
                clearImagesByDisplay.removeAll()
            }
        }

        var newImages = [MenuBarItemInfo: CGImage]()

        for section in sections {
            guard
                await appState.isScreenCaptureAllowed,
                !Task.isCancelled
            else {
                return
            }
            guard await !appState.itemManager.itemCache[section].isEmpty else {
                continue
            }
            let sectionImages = await createImages(for: section, screen: screen)
            guard !sectionImages.isEmpty else {
                Logger.imageCache.warning("Update image cache failed for \(section.logString)")
                continue
            }
            newImages.merge(sectionImages) { (_, new) in new }
        }

        guard
            await appState.isScreenCaptureAllowed,
            !Task.isCancelled
        else {
            return
        }

        await MainActor.run { [newImages] in
            images.merge(newImages) { (_, new) in new }
        }

        self.screen = screen
        self.menuBarHeight = screen.getMenuBarHeight()
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isClearAppearance = await appState.appearanceManager.configuration.shapeKind == .clear

        if !isIceBarPresented && !isSearchPresented && !isClearAppearance {
            guard await appState.navigationState.isAppFrontmost else {
                logSkippingCache(reason: "Ice Bar not visible, app not frontmost")
                return
            }
            guard await appState.navigationState.isSettingsPresented else {
                logSkippingCache(reason: "Ice Bar not visible, Settings not visible")
                return
            }
            guard case .menuBarLayout = await appState.navigationState.settingsNavigationIdentifier else {
                logSkippingCache(reason: "Ice Bar not visible, Settings visible but not on Menu Bar Layout")
                return
            }
        }

        guard await !appState.itemManager.isMovingItem else {
            logSkippingCache(reason: "an item is currently being moved")
            return
        }

        guard await !appState.itemManager.itemHasRecentlyMoved else {
            logSkippingCache(reason: "an item was recently moved")
            return
        }

        await updateCacheWithoutChecks(sections: sections)
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if await appState.appearanceManager.configuration.shapeKind == .clear {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }
}

// MARK: - Logger

private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}
