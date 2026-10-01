/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    // Global shortcuts take a key combination away from every app, and each of
    // these defaults was already one macOS or a common app uses (⌘⇧T reopens a
    // tab, ⌘⇧P opens a command palette, ⌃` toggles an editor's terminal...).
    // They start unassigned; Settings > Shortcuts sets one up deliberately.
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel")
    static let colorPickerPanel = Self("colorPickerPanel")
    static let screenAssistantPanel = Self("screenAssistantPanel")
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek")
    static let toggleNotchOpen = Self("toggleNotchOpen")
    static let toggleTerminalTab = Self("toggleTerminalTab")
    static let startDemoTimer = Self("startDemoTimer")
    static let toggleCaffeinate = Self("toggleCaffeinate")
}
