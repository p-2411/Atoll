//
//  MenuBarLayout.swift
//  DynamicIsland
//
//  What else is in the menu bar beside the notch, so a live activity can get
//  out of its way.
//

import AppKit
import ApplicationServices
import Combine
import os

/// Tracks where the menu bar's own contents sit either side of the notch.
///
/// A live activity draws into the strip of menu bar beside the notch: the
/// frontmost app's menus on the left, status items on the right. macOS offers
/// no way to reserve that space -- both `NSScreen.auxiliaryTop…Area`s are
/// read-only -- and sliding the island sideways does not help either, because
/// on a notched Mac its surface cannot leave the camera housing. So Atoll
/// measures what is already there, and while a live activity would cover any
/// of it, draws only the bare notch.
///
/// The measurement is the accessibility API's view of the menu bar. On macOS 27
/// status items are no longer windows of their own (MenuBarAgent draws the whole
/// bar), so the accessibility tree is the one public place their frames appear.
///
/// Both edges are kept as insets from the edges of the screen they were read
/// on, because every display carries its own copy of the menu bar, laid out
/// against its own edges.
@MainActor
final class MenuBarLayout: ObservableObject {
    static let shared = MenuBarLayout()

    /// How far the menu bar's contents reach in from each edge of the screen.
    /// A `nil` side has nothing measured on it and constrains nothing.
    struct Obstacles: Equatable, Sendable {
        /// Screen's left edge to the end of whatever sits left of the notch.
        var leftInset: CGFloat?
        /// Screen's right edge to the start of whatever sits right of the notch.
        var rightInset: CGFloat?
    }

    /// A screen's frame and, if it has one, the x-range of its notch, both in
    /// global AppKit coordinates. Captured on the main actor because `NSScreen`
    /// cannot leave it.
    struct ScreenGeometry: Sendable {
        var frame: CGRect
        var notchXRange: ClosedRange<CGFloat>?

        @MainActor
        init(_ screen: NSScreen) {
            frame = screen.frame
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let notchMinX = screen.frame.minX + left.width
                let notchMaxX = screen.frame.maxX - right.width
                notchXRange = notchMinX < notchMaxX ? notchMinX...notchMaxX : nil
            } else {
                notchXRange = nil
            }
        }

        init(frame: CGRect, notchXRange: ClosedRange<CGFloat>?) {
            self.frame = frame
            self.notchXRange = notchXRange
        }
    }

    /// Empty when nothing is known -- no accessibility permission, nothing
    /// tracking, or a menu bar that did not answer. Callers treat that as "no
    /// constraint" rather than guessing, so the island behaves as it always has.
    @Published private(set) var obstacles = Obstacles()

    /// Breathing room between the island and whatever it would otherwise touch.
    nonisolated static let clearanceGap: CGFloat = 8

    /// Menus change with the frontmost app and status items come and go, so a
    /// slow poll backs up the notifications. It runs only while something
    /// actually needs the measurement.
    private static let pollInterval: TimeInterval = 3

    /// Every this many polls, look for status items from apps that were already
    /// running but have only just added one.
    private static let pollsPerOwnerRescan = 20

    private static let logger = os.Logger(subsystem: "com.Ebullioscopic.Atoll", category: "MenuBarLayout")

    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var trackers = 0
    private var inFlight = false
    private var pollsSinceOwnerScan = 0

    /// Processes known to own status items. Asking every running app on every
    /// poll would be wasteful, so they are found once and reused; `nil` forces
    /// a fresh search, which happens whenever an app launches or quits.
    private var statusItemOwners: [pid_t]?

    private init() {}

    /// Whether an island surface `surfaceWidth` wide, centred in `screenFrame`,
    /// would cover anything in the menu bar, allowing `gap` of breathing room.
    nonisolated static func surfaceCollides(
        surfaceWidth: CGFloat,
        screenFrame: CGRect,
        obstacles: Obstacles,
        gap: CGFloat
    ) -> Bool {
        guard surfaceWidth > 0 else { return false }
        let surfaceLeft = screenFrame.midX - surfaceWidth / 2
        let surfaceRight = screenFrame.midX + surfaceWidth / 2

        if let leftInset = obstacles.leftInset, screenFrame.minX + leftInset + gap > surfaceLeft {
            return true
        }
        if let rightInset = obstacles.rightInset, screenFrame.maxX - rightInset - gap < surfaceRight {
            return true
        }
        return false
    }

    /// Reduces menu bar item frames (global AppKit coordinates) to the insets.
    ///
    /// Each item counts on whichever side of its screen's centre it sits, and
    /// only the one reaching nearest the centre matters, since that is what a
    /// live activity runs into first. Items overlapping a notch are skipped:
    /// macOS hides those behind the camera housing, so there is nothing visible
    /// there to cover.
    nonisolated static func obstacles(itemFrames: [CGRect], screens: [ScreenGeometry]) -> Obstacles {
        var result = Obstacles()
        for item in itemFrames where item.width > 0 {
            let centre = CGPoint(x: item.midX, y: item.midY)
            guard let screen = screens.first(where: { $0.frame.contains(centre) }) else { continue }
            if let notch = screen.notchXRange, item.maxX > notch.lowerBound, item.minX < notch.upperBound {
                continue
            }

            if item.midX < screen.frame.midX {
                result.leftInset = max(result.leftInset ?? 0, item.maxX - screen.frame.minX)
            } else {
                result.rightInset = max(result.rightInset ?? 0, screen.frame.maxX - item.minX)
            }
        }
        return result
    }

    /// Begin measuring. Balanced by `stopTracking()`; nested calls are counted,
    /// so several displays can ask at once without one stopping the others.
    func startTracking() {
        trackers += 1
        guard trackers == 1 else { return }

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.statusItemOwners = nil }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.statusItemOwners = nil }
            },
        ]

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refresh()
    }

    func stopTracking() {
        guard trackers > 0 else { return }
        trackers -= 1
        guard trackers == 0 else { return }

        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        pollTimer?.invalidate()
        pollTimer = nil
        obstacles = Obstacles()
    }

    func refresh() {
        guard !inFlight else { return }
        guard AXIsProcessTrusted() else {
            obstacles = Obstacles()
            return
        }

        pollsSinceOwnerScan += 1
        if pollsSinceOwnerScan >= Self.pollsPerOwnerRescan {
            statusItemOwners = nil
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ownerSearch = statusItemOwners == nil ? Self.statusItemOwnerCandidates() : nil
        let pidsToRead = ownerSearch ?? statusItemOwners ?? []
        let screens = NSScreen.screens.map(ScreenGeometry.init)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0

        // Off the main actor: these are cross-process calls, and an app that has
        // stopped answering would otherwise take the notch's UI down with it.
        inFlight = true
        Task.detached(priority: .utility) {
            let scan = Self.readMenuBar(
                frontmostPID: frontmostPID,
                statusItemPIDs: pidsToRead,
                primaryMaxY: primaryMaxY,
                deadline: ownerSearch == nil ? Self.pollDeadline : Self.ownerSearchDeadline
            )
            let measured = Self.obstacles(itemFrames: scan.itemFrames, screens: screens)
            await MainActor.run {
                self.inFlight = false
                guard self.trackers > 0 else { return }
                if ownerSearch != nil {
                    self.statusItemOwners = scan.statusItemOwners
                    self.pollsSinceOwnerScan = 0
                    Self.logger.notice("Status items found in \(scan.statusItemOwners.count, privacy: .public) processes")
                }
                if self.obstacles != measured {
                    self.obstacles = measured
                    Self.logger.notice("Menu bar insets left=\(measured.leftInset ?? -1, privacy: .public) right=\(measured.rightInset ?? -1, privacy: .public)")
                }
            }
        }
    }

    /// Running apps that might own status items, with the system's menu bar
    /// hosts first so a search cut short by the deadline still covers them.
    private static func statusItemOwnerCandidates() -> [pid_t] {
        let systemHosts: Set<String> = [
            "com.apple.MenuBarAgent",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.TextInputMenuAgent",
            "com.apple.Spotlight",
        ]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != ownPID
        }

        func rank(_ app: NSRunningApplication) -> Int {
            if let id = app.bundleIdentifier, systemHosts.contains(id) { return 0 }
            switch app.activationPolicy {
            case .accessory: return 1
            case .regular: return 2
            default: return 3
            }
        }
        return apps.sorted { rank($0) < rank($1) }.map(\.processIdentifier)
    }

    /// Longest a regular poll may take, and a search through every running app.
    /// A menu bar with many items could otherwise reach minutes at the
    /// per-element timeout, and no further measurement is taken until it returns.
    nonisolated private static let pollDeadline: TimeInterval = 1
    nonisolated private static let ownerSearchDeadline: TimeInterval = 3

    /// Per-element messaging timeout. `AXUIElementSetMessagingTimeout` applies
    /// only to the element it is called on -- it does not carry to the children
    /// that element hands back -- so every element messaged here is given its
    /// own, or a hung app would still block on the ones that inherited nothing.
    nonisolated private static let elementTimeout: Float = 0.25

    private struct MenuBarScan: Sendable {
        var itemFrames: [CGRect] = []
        var statusItemOwners: [pid_t] = []
    }

    /// Frames of the frontmost app's menus and of every status item owned by
    /// `statusItemPIDs`, converted to global AppKit coordinates.
    nonisolated private static func readMenuBar(
        frontmostPID: pid_t?,
        statusItemPIDs: [pid_t],
        primaryMaxY: CGFloat,
        deadline: TimeInterval
    ) -> MenuBarScan {
        let startedAt = Date()
        func timeLeft() -> Bool { Date().timeIntervalSince(startedAt) < deadline }

        var scan = MenuBarScan()
        if let frontmostPID {
            scan.itemFrames += itemFrames(pid: frontmostPID, barAttribute: kAXMenuBarAttribute, primaryMaxY: primaryMaxY, timeLeft: timeLeft) ?? []
        }
        for pid in statusItemPIDs {
            // Whatever has been measured so far is still usable; a scan that has
            // run long is one where something is not answering.
            guard timeLeft() else { break }
            guard let frames = itemFrames(pid: pid, barAttribute: kAXExtrasMenuBarAttribute, primaryMaxY: primaryMaxY, timeLeft: timeLeft) else {
                continue
            }
            scan.statusItemOwners.append(pid)
            scan.itemFrames += frames
        }
        return scan
    }

    /// Frames of the children of `pid`'s menu bar named by `barAttribute`, or
    /// `nil` if it has no such bar or did not answer.
    nonisolated private static func itemFrames(
        pid: pid_t,
        barAttribute: String,
        primaryMaxY: CGFloat,
        timeLeft: () -> Bool
    ) -> [CGRect]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, elementTimeout)

        var barValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, barAttribute as CFString, &barValue) == .success,
              let barValue, CFGetTypeID(barValue) == AXUIElementGetTypeID()
        else { return nil }
        let bar = unsafeBitCast(barValue, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(bar, elementTimeout)

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let items = childrenValue as? [AXUIElement]
        else { return nil }

        var frames: [CGRect] = []
        for item in items {
            guard timeLeft() else { break }
            AXUIElementSetMessagingTimeout(item, elementTimeout)

            // Position and size in one round trip rather than two.
            var values: CFArray?
            let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(item, attributes, AXCopyMultipleAttributeOptions(), &values) == .success,
                  let pair = values as? [AnyObject], pair.count == 2,
                  CFGetTypeID(pair[0]) == AXValueGetTypeID(),
                  CFGetTypeID(pair[1]) == AXValueGetTypeID()
            else { continue }

            var origin = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(pair[1] as! AXValue, .cgSize, &size)
            else { continue }

            // Accessibility measures from the top of the primary screen, AppKit
            // from its bottom.
            frames.append(CGRect(x: origin.x, y: primaryMaxY - origin.y - size.height, width: size.width, height: size.height))
        }
        return frames
    }
}
