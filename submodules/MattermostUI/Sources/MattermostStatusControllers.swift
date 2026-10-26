import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import ItemListDatePickerItem
import PresentationDataUtils
import MattermostSync
import MattermostSyncCore

// Phase 3F: Settings → Status (online / away / do not disturb with an end / offline) and Settings → Custom Status
// (emoji, text, when it clears; recent and suggested statuses). Both write to the server at once; the screens follow
// the account's own status (`MattermostProfile.ownStatus`), so a change on another device shows here too.

// MARK: - Icons and texts shared with Settings

public enum MattermostStatusAppearance {
    public static func color(_ status: MattermostOwnStatus.Status) -> UIColor {
        switch status {
        case .online:
            return UIColor(rgb: 0x34c759)
        case .away:
            return UIColor(rgb: 0xffbc1f)
        case .dnd:
            return UIColor(rgb: 0xff3b30)
        case .offline:
            return UIColor(rgb: 0x8e8e93)
        }
    }

    private static func symbolName(_ status: MattermostOwnStatus.Status) -> String {
        switch status {
        case .online:
            return "checkmark"
        case .away:
            return "clock.fill"
        case .dnd:
            return "minus"
        case .offline:
            return "circle"
        }
    }

    /// A Settings row icon: the status colour with its glyph (30×30, rounded like Telegram's settings icons).
    public static func settingsIcon(_ status: MattermostOwnStatus.Status) -> UIImage {
        let size = CGSize(width: 30.0, height: 30.0)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIBezierPath(roundedRect: rect, cornerRadius: 8.0).addClip()
            self.color(status).setFill()
            context.fill(rect)
            let configuration = UIImage.SymbolConfiguration(pointSize: 15.0, weight: .bold)
            if let glyph = UIImage(systemName: self.symbolName(status), withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(in: CGRect(x: (size.width - glyph.size.width) / 2.0, y: (size.height - glyph.size.height) / 2.0, width: glyph.size.width, height: glyph.size.height))
            }
        }
    }

    /// A dot in the status colour (lists, the status menu).
    public static func dot(_ status: MattermostOwnStatus.Status, diameter: CGFloat = 12.0) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            self.color(status).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
        }
    }

    /// An emoji as a row icon (a custom emoji `:name:` shows its name).
    public static func emojiIcon(_ emoji: String, side: CGFloat = 30.0) -> UIImage {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let isName = emoji.hasPrefix(":") && emoji.count > 2
            let font: UIFont = isName ? UIFont.systemFont(ofSize: side * 0.3, weight: .semibold) : (UIFont(name: "AppleColorEmoji", size: side * 0.8) ?? UIFont.systemFont(ofSize: side * 0.8))
            let text = NSAttributedString(string: isName ? String(emoji.dropFirst().dropLast()) : emoji, attributes: [.font: font, .foregroundColor: UIColor.gray])
            var bounds = text.boundingRect(with: CGSize(width: 1000.0, height: 1000.0), options: [.usesLineFragmentOrigin], context: nil)
            let scale = min(1.0, size.width / max(1.0, bounds.width))
            bounds.size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let context = UIGraphicsGetCurrentContext() {
                context.saveGState()
                context.translateBy(x: (size.width - bounds.width) / 2.0, y: (size.height - bounds.height) / 2.0)
                context.scaleBy(x: scale, y: scale)
                text.draw(at: .zero)
                context.restoreGState()
            }
        }
    }

    public static func title(_ status: MattermostOwnStatus.Status, strings: PresentationStrings) -> String {
        switch status {
        case .online:
            return strings.Relay_Status_Online
        case .away:
            return strings.Relay_Status_Away
        case .dnd:
            return strings.Relay_Status_DoNotDisturb
        case .offline:
            return strings.Relay_Status_Offline
        }
    }

    /// "Do Not Disturb · Until 17:30" for Settings rows.
    public static func label(_ status: MattermostOwnStatus, strings: PresentationStrings) -> String {
        let title = self.title(status.status, strings: strings)
        if status.status == .dnd, let end = status.dndEnd, end > Date() {
            return title + " · " + strings.Relay_Status_Until(self.shortDate(end)).string
        }
        return title
    }

    /// "17:30" today, else "Tue 9:00", else a date.
    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day, days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    public static func doNotDisturbTitle(_ duration: DoNotDisturbDuration, strings: PresentationStrings) -> String {
        switch duration {
        case .indefinitely:
            return strings.Relay_Status_Dnd_DontClear
        case .thirtyMinutes:
            return strings.Relay_Status_Dnd_ThirtyMinutes
        case .oneHour:
            return strings.Relay_Status_Dnd_OneHour
        case .twoHours:
            return strings.Relay_Status_Dnd_TwoHours
        case .tomorrow:
            return strings.Relay_Status_Dnd_Tomorrow
        case let .until(date):
            return strings.Relay_Status_Until(self.shortDate(date)).string
        }
    }

    public static func customStatusDurationTitle(_ duration: CustomStatusDuration, strings: PresentationStrings) -> String {
        switch duration {
        case .dontClear:
            return strings.Relay_CustomStatus_Duration_DontClear
        case .thirtyMinutes:
            return strings.Relay_CustomStatus_Duration_ThirtyMinutes
        case .oneHour:
            return strings.Relay_CustomStatus_Duration_OneHour
        case .fourHours:
            return strings.Relay_CustomStatus_Duration_FourHours
        case .today:
            return strings.Relay_CustomStatus_Duration_Today
        case .thisWeek:
            return strings.Relay_CustomStatus_Duration_ThisWeek
        case let .dateAndTime(date):
            return strings.Relay_CustomStatus_Until(self.shortDate(date)).string
        }
    }

    /// "🌴 On vacation" (or the emoji alone).
    public static func customStatusText(_ status: MattermostCustomStatus) -> String {
        return status.text.isEmpty ? status.emoji : status.emoji + " " + status.text
    }
}

// MARK: - Status

private final class StatusArguments {
    let select: (MattermostOwnStatus.Status) -> Void
    let selectDoNotDisturb: (DoNotDisturbDuration) -> Void
    let toggleCustomDate: () -> Void
    let toggleCustomTime: () -> Void
    let updateCustomDate: (Int32) -> Void
    let confirmCustomDate: () -> Void
    let openCustomStatus: () -> Void

    init(select: @escaping (MattermostOwnStatus.Status) -> Void, selectDoNotDisturb: @escaping (DoNotDisturbDuration) -> Void, toggleCustomDate: @escaping () -> Void, toggleCustomTime: @escaping () -> Void, updateCustomDate: @escaping (Int32) -> Void, confirmCustomDate: @escaping () -> Void, openCustomStatus: @escaping () -> Void) {
        self.select = select
        self.selectDoNotDisturb = selectDoNotDisturb
        self.toggleCustomDate = toggleCustomDate
        self.toggleCustomTime = toggleCustomTime
        self.updateCustomDate = updateCustomDate
        self.confirmCustomDate = confirmCustomDate
        self.openCustomStatus = openCustomStatus
    }
}

private enum StatusEntry: ItemListNodeEntry {
    case status(index: Int, status: MattermostOwnStatus.Status, title: String, subtitle: String?, checked: Bool)
    case footer(section: Int32, text: String)
    case header(section: Int32, text: String)
    case duration(index: Int, duration: DoNotDisturbDuration, title: String)
    case custom(title: String)
    case customDate(title: String, date: Int32, pickingDate: Bool, pickingTime: Bool)
    case customConfirm(title: String)
    case customStatus(title: String, label: String, icon: UIImage?)

    var section: ItemListSectionId {
        switch self {
        case .status:
            return 0
        case let .footer(section, _), let .header(section, _):
            return section
        case .duration, .custom, .customDate, .customConfirm:
            return 1
        case .customStatus:
            return 2
        }
    }

    var stableId: Int {
        switch self {
        case let .status(index, _, _, _, _):
            return index
        case let .footer(section, _):
            return 1000 + Int(section)
        case let .header(section, _):
            return 900 + Int(section)
        case let .duration(index, _, _):
            return 100 + index
        case .custom:
            return 150
        case .customDate:
            return 151
        case .customConfirm:
            return 152
        case .customStatus:
            return 200
        }
    }

    private var sortKey: Int {
        switch self {
        case let .header(section, _):
            return Int(section) * 1000
        case let .footer(section, _):
            return Int(section) * 1000 + 999
        default:
            return Int(self.section) * 1000 + 1 + self.stableId
        }
    }

    static func <(lhs: StatusEntry, rhs: StatusEntry) -> Bool {
        return lhs.sortKey < rhs.sortKey
    }

    static func ==(lhs: StatusEntry, rhs: StatusEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.status(a1, a2, a3, a4, a5), .status(b1, b2, b3, b4, b5)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4 && a5 == b5
        case let (.footer(a1, a2), .footer(b1, b2)), let (.header(a1, a2), .header(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.duration(a1, a2, a3), .duration(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.custom(a), .custom(b)), let (.customConfirm(a), .customConfirm(b)):
            return a == b
        case let (.customDate(a1, a2, a3, a4), .customDate(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.customStatus(a1, a2, _), .customStatus(b1, b2, _)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! StatusArguments
        switch self {
        case let .status(_, status, title, subtitle, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: MattermostStatusAppearance.dot(status), iconSize: CGSize(width: 12.0, height: 12.0), title: title, subtitle: subtitle, style: .right, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(status)
            })
        case let .footer(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .duration(_, duration, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.selectDoNotDisturb(duration)
            })
        case let .custom(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.toggleCustomDate()
            })
        case let .customDate(title, date, pickingDate, pickingTime):
            return ItemListDatePickerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, date: date, minDate: Int32(Date().timeIntervalSince1970), title: title, displayingDateSelection: pickingDate, displayingTimeSelection: pickingTime, sectionId: self.section, style: .blocks, toggleDateSelection: {
                arguments.toggleCustomDate()
            }, toggleTimeSelection: {
                arguments.toggleCustomTime()
            }, updated: { value in
                arguments.updateCustomDate(value)
            })
        case let .customConfirm(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.confirmCustomDate()
            })
        case let .customStatus(title, label, icon):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, label: label, sectionId: self.section, style: .blocks, action: {
                arguments.openCustomStatus()
            })
        }
    }
}

private struct StatusScreenState: Equatable {
    var showsDurations: Bool = false
    var showsCustomDate: Bool = false
    var pickingDate: Bool = false
    var pickingTime: Bool = false
    var customDate: Int32 = Int32(Date().timeIntervalSince1970) + 60 * 60
    var busy: Bool = false
}

/// Settings → Status. `openCustomStatus` opens the custom status screen (PeerInfoScreen supplies its emoji picker).
public func mattermostStatusController(context: AccountContext, openCustomStatus: @escaping () -> Void) -> ViewController {
    let accountId = context.account.id
    let statePromise = ValuePromise(StatusScreenState(), ignoreRepeated: true)
    let stateValue = Atomic(value: StatusScreenState())
    let updateState: ((StatusScreenState) -> StatusScreenState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let actionDisposable = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?

    let apply: (MattermostOwnStatus.Status, DoNotDisturbDuration) -> Void = { status, duration in
        updateState { state in
            var state = state
            state.busy = true
            return state
        }
        actionDisposable.set((MattermostProfile.setStatus(accountId: accountId, status, doNotDisturb: duration)
        |> deliverOnMainQueue).start(error: { error in
            updateState { state in
                var state = state
                state.busy = false
                return state
            }
            mattermostPresentError(error, context: context, present: presentImpl)
        }, completed: {
            updateState { state in
                var state = state
                state.busy = false
                state.showsDurations = false
                state.showsCustomDate = false
                return state
            }
        }))
    }

    let arguments = StatusArguments(select: { status in
        if status == .dnd {
            updateState { state in
                var state = state
                state.showsDurations = !state.showsDurations
                return state
            }
            return
        }
        apply(status, .indefinitely)
    }, selectDoNotDisturb: { duration in
        apply(.dnd, duration)
    }, toggleCustomDate: {
        updateState { state in
            var state = state
            if !state.showsCustomDate {
                state.showsCustomDate = true
                state.pickingDate = true
                state.pickingTime = false
            } else {
                state.pickingDate = !state.pickingDate
                if state.pickingDate {
                    state.pickingTime = false
                }
            }
            return state
        }
    }, toggleCustomTime: {
        updateState { state in
            var state = state
            state.pickingTime = !state.pickingTime
            if state.pickingTime {
                state.pickingDate = false
            }
            return state
        }
    }, updateCustomDate: { value in
        updateState { state in
            var state = state
            state.customDate = value
            return state
        }
    }, confirmCustomDate: {
        let date = Date(timeIntervalSince1970: TimeInterval(stateValue.with { $0.customDate }))
        apply(.dnd, .until(date))
    }, openCustomStatus: {
        openCustomStatus()
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), MattermostProfile.ownStatus(accountId: accountId), MattermostProfile.ownProfileFields(accountId: accountId))
    |> deliverOnMainQueue
    |> map { presentationData, state, ownStatus, fields -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [StatusEntry] = []
        let current = ownStatus?.status
        for (index, status) in MattermostOwnStatus.Status.allCases.enumerated() {
            var subtitle: String?
            if status == .dnd, current == .dnd, let end = ownStatus?.dndEnd, end > Date() {
                subtitle = strings.Relay_Status_Until(MattermostStatusAppearance.shortDate(end)).string
            }
            entries.append(.status(index: index, status: status, title: MattermostStatusAppearance.title(status, strings: strings), subtitle: subtitle, checked: current == status))
        }
        entries.append(.footer(section: 0, text: strings.Relay_Status_Footer))
        if state.showsDurations {
            entries.append(.header(section: 1, text: strings.Relay_Status_DndHeader))
            for (index, duration) in DoNotDisturbDuration.presets.enumerated() {
                entries.append(.duration(index: index, duration: duration, title: MattermostStatusAppearance.doNotDisturbTitle(duration, strings: strings)))
            }
            if state.showsCustomDate {
                entries.append(.customDate(title: strings.Relay_Status_Dnd_Ends, date: state.customDate, pickingDate: state.pickingDate, pickingTime: state.pickingTime))
                entries.append(.customConfirm(title: strings.Relay_Status_Dnd_TurnOn))
            } else {
                entries.append(.custom(title: strings.Relay_Status_Dnd_Custom))
            }
            entries.append(.footer(section: 1, text: strings.Relay_Status_DndFooter))
        }
        if fields?.customStatusesEnabled ?? true {
            let custom = ownStatus?.customStatus
            entries.append(.customStatus(title: strings.Relay_Status_CustomStatus, label: custom.map(MattermostStatusAppearance.customStatusText) ?? strings.Relay_Status_SetCustomStatus, icon: nil))
        }
        let rightButton: ItemListNavigationButton? = state.busy ? ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {}) : nil
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_Status_Title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    #if DEBUG
    controller.debugName = "status"
    #endif
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    #if DEBUG
    controller.debugState = {
        let own = MattermostProfile.currentOwnStatus(accountId: accountId)
        let state = stateValue.with { $0 }
        return ["screen": "status", "status": own?.status.rawValue ?? "", "manual": own?.isManual ?? false, "dndEnd": own?.dndEnd.map { Int($0.timeIntervalSince1970) } ?? 0, "customStatus": own?.customStatus.map(MattermostStatusAppearance.customStatusText) ?? "", "showsDurations": state.showsDurations, "busy": state.busy]
    }
    controller.debugActions = [
        "select": { command in
            if let raw = command["status"] as? String, let status = MattermostOwnStatus.Status(rawValue: raw) {
                arguments.select(status)
            }
        },
        "dnd": { command in
            switch command["duration"] as? String ?? "" {
            case "30m":
                arguments.selectDoNotDisturb(.thirtyMinutes)
            case "1h":
                arguments.selectDoNotDisturb(.oneHour)
            case "2h":
                arguments.selectDoNotDisturb(.twoHours)
            case "tomorrow":
                arguments.selectDoNotDisturb(.tomorrow)
            case "custom":
                let minutes = mattermostDebugInt(command, "minutes") ?? 90
                if !stateValue.with({ $0.showsCustomDate }) {
                    arguments.toggleCustomDate()
                }
                arguments.updateCustomDate(Int32(Date().timeIntervalSince1970) + Int32(minutes * 60))
                arguments.confirmCustomDate()
            default:
                arguments.selectDoNotDisturb(.indefinitely)
            }
        },
        "custom-status": { _ in
            arguments.openCustomStatus()
        }
    ]
    #endif
    return controller
}

// MARK: - Custom status

private final class MattermostEmojiRowTag: ItemListItemTag {
    func isEqual(to other: ItemListItemTag) -> Bool {
        return other is MattermostEmojiRowTag
    }
}

private final class CustomStatusArguments {
    let pickEmoji: () -> Void
    let updateText: (String) -> Void
    let selectDuration: (CustomStatusDuration?) -> Void
    let toggleDate: () -> Void
    let toggleTime: () -> Void
    let updateDate: (Int32) -> Void
    let apply: (MattermostCustomStatus, CustomStatusDuration) -> Void
    let clear: () -> Void

    init(pickEmoji: @escaping () -> Void, updateText: @escaping (String) -> Void, selectDuration: @escaping (CustomStatusDuration?) -> Void, toggleDate: @escaping () -> Void, toggleTime: @escaping () -> Void, updateDate: @escaping (Int32) -> Void, apply: @escaping (MattermostCustomStatus, CustomStatusDuration) -> Void, clear: @escaping () -> Void) {
        self.pickEmoji = pickEmoji
        self.updateText = updateText
        self.selectDuration = selectDuration
        self.toggleDate = toggleDate
        self.toggleTime = toggleTime
        self.updateDate = updateDate
        self.apply = apply
        self.clear = clear
    }
}

private enum CustomStatusEntry: ItemListNodeEntry {
    case header(section: Int32, text: String)
    case footer(section: Int32, text: String)
    case emoji(title: String, emoji: String)
    case text(placeholder: String, value: String, enabled: Bool)
    case duration(index: Int, title: String, duration: CustomStatusDuration?, checked: Bool)
    case date(title: String, date: Int32, pickingDate: Bool, pickingTime: Bool)
    case recent(index: Int, status: MattermostCustomStatus, label: String)
    case suggestion(index: Int, status: MattermostCustomStatus, duration: CustomStatusDuration, label: String)
    case clear(title: String)
    case disabled(String)

    var section: ItemListSectionId {
        switch self {
        case let .header(section, _), let .footer(section, _):
            return section
        case .emoji, .text, .disabled:
            return 0
        case .duration, .date:
            return 1
        case .recent:
            return 2
        case .suggestion:
            return 3
        case .clear:
            return 4
        }
    }

    var stableId: Int {
        switch self {
        case let .header(section, _):
            return 10_000 + Int(section)
        case let .footer(section, _):
            return 20_000 + Int(section)
        case .emoji:
            return 1
        case .text:
            return 2
        case .disabled:
            return 3
        case let .duration(index, _, _, _):
            return 100 + index
        case .date:
            return 199
        case let .recent(index, _, _):
            return 200 + index
        case let .suggestion(index, _, _, _):
            return 300 + index
        case .clear:
            return 400
        }
    }

    private var sortKey: Int {
        switch self {
        case let .header(section, _):
            return Int(section) * 1000
        case let .footer(section, _):
            return Int(section) * 1000 + 999
        default:
            return Int(self.section) * 1000 + 1 + (self.stableId % 100)
        }
    }

    static func <(lhs: CustomStatusEntry, rhs: CustomStatusEntry) -> Bool {
        return lhs.sortKey < rhs.sortKey
    }

    static func ==(lhs: CustomStatusEntry, rhs: CustomStatusEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.header(a1, a2), .header(b1, b2)), let (.footer(a1, a2), .footer(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.emoji(a1, a2), .emoji(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.text(a1, a2, a3), .text(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.duration(a1, a2, a3, a4), .duration(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.date(a1, a2, a3, a4), .date(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.recent(a1, a2, a3), .recent(b1, b2, b3)):
            return a1 == b1 && a2 == b2 && a3 == b3
        case let (.suggestion(a1, a2, a3, a4), .suggestion(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        case let (.clear(a), .clear(b)), let (.disabled(a), .disabled(b)):
            return a == b
        default:
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! CustomStatusArguments
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .footer(_, text), let .disabled(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .emoji(title, emoji):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: MattermostStatusAppearance.emojiIcon(emoji, side: 28.0), title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.pickEmoji()
            }, tag: MattermostEmojiRowTag())
        case let .text(placeholder, value, enabled):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: value, placeholder: placeholder, type: .regular(capitalization: true, autocorrection: true), clearType: .always, maxLength: CustomStatusRules.textMaxLength, enabled: enabled, sectionId: self.section, textUpdated: { text in
                arguments.updateText(text)
            }, action: {})
        case let .duration(_, title, duration, checked):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, style: .left, checked: checked, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.selectDuration(duration)
            })
        case let .date(title, date, pickingDate, pickingTime):
            return ItemListDatePickerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: presentationData.dateTimeFormat, date: date, minDate: Int32(Date().timeIntervalSince1970), title: title, displayingDateSelection: pickingDate, displayingTimeSelection: pickingTime, sectionId: self.section, style: .blocks, toggleDateSelection: {
                arguments.toggleDate()
            }, toggleTimeSelection: {
                arguments.toggleTime()
            }, updated: { value in
                arguments.updateDate(value)
            })
        case let .recent(_, status, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: MattermostStatusAppearance.emojiIcon(status.emoji, side: 28.0), title: status.text, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.apply(status, CustomStatusDuration(apiValue: status.duration) ?? .dontClear)
            })
        case let .suggestion(_, status, duration, label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: MattermostStatusAppearance.emojiIcon(status.emoji, side: 28.0), title: status.text, label: label, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.apply(status, duration)
            })
        case let .clear(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .center, sectionId: self.section, style: .blocks, action: {
                arguments.clear()
            })
        }
    }
}

private struct CustomStatusScreenState: Equatable {
    /// The emoji's Mattermost name (empty: the default emoji).
    var emojiName: String
    var text: String
    /// nil: "Choose Date and Time".
    var duration: CustomStatusDuration?
    var date: Int32
    var pickingDate: Bool = false
    var pickingTime: Bool = false
    var recent: [MattermostCustomStatus] = []
    var busy: Bool = false
}

/// Settings → Custom Status. `pickEmoji(sourceView, completion)` shows an emoji picker anchored to the emoji row, calls
/// `completion` with the chosen emoji (Unicode, or `:name:`) and returns the picker (dismissed with the screen).
public func mattermostCustomStatusController(context: AccountContext, pickEmoji: @escaping (UIView, @escaping (String) -> Void) -> ViewController?) -> ViewController {
    let accountId = context.account.id
    let current = MattermostProfile.currentOwnStatus(accountId: accountId)?.customStatus
    var initialDuration: CustomStatusDuration? = .today
    var initialDate = Int32(Date().timeIntervalSince1970) + 60 * 60
    if let current {
        if current.duration == "date_and_time", let expiresAt = current.expiresAt {
            initialDuration = nil
            initialDate = Int32(expiresAt.timeIntervalSince1970)
        } else {
            initialDuration = CustomStatusDuration(apiValue: current.duration) ?? .dontClear
        }
    }
    let initial = CustomStatusScreenState(emojiName: current?.emojiName ?? "", text: current?.text ?? "", duration: initialDuration, date: initialDate)
    let statePromise = ValuePromise(initial, ignoreRepeated: true)
    let stateValue = Atomic(value: initial)
    let updateState: ((CustomStatusScreenState) -> CustomStatusScreenState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    let actionDisposable = MetaDisposable()
    let recentDisposable = MetaDisposable()
    var presentImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    var emojiSourceView: (() -> UIView?)?
    weak var emojiPicker: ViewController?

    recentDisposable.set((MattermostProfile.recentCustomStatuses(accountId: accountId)
    |> deliverOnMainQueue).start(next: { recent in
        updateState { state in
            var state = state
            state.recent = recent
            return state
        }
    }))

    let run: (Signal<Never, MattermostDirectoryError>) -> Void = { signal in
        updateState { state in
            var state = state
            state.busy = true
            return state
        }
        actionDisposable.set((signal
        |> deliverOnMainQueue).start(error: { error in
            updateState { state in
                var state = state
                state.busy = false
                return state
            }
            mattermostPresentError(error, context: context, present: presentImpl)
        }, completed: {
            dismissImpl?()
        }))
    }

    let submit: () -> Void = {
        let state = stateValue.with { $0 }
        if state.busy {
            return
        }
        if state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.emojiName.isEmpty {
            run(MattermostProfile.clearCustomStatus(accountId: accountId))
            return
        }
        let duration = state.duration ?? .dateAndTime(Date(timeIntervalSince1970: TimeInterval(state.date)))
        run(MattermostProfile.setCustomStatus(accountId: accountId, emojiName: state.emojiName, text: state.text, duration: duration))
    }

    let arguments = CustomStatusArguments(pickEmoji: {
        guard let sourceView = emojiSourceView?() else {
            return
        }
        emojiPicker = pickEmoji(sourceView, { emoji in
            guard let name = MattermostCustomStatus.emojiName(forDisplayEmoji: emoji) else {
                return
            }
            updateState { state in
                var state = state
                state.emojiName = name
                return state
            }
        })
    }, updateText: { text in
        updateState { state in
            var state = state
            state.text = text
            return state
        }
    }, selectDuration: { duration in
        updateState { state in
            var state = state
            state.duration = duration
            if duration == nil {
                state.pickingDate = true
                state.pickingTime = false
            } else {
                state.pickingDate = false
                state.pickingTime = false
            }
            return state
        }
    }, toggleDate: {
        updateState { state in
            var state = state
            state.pickingDate = !state.pickingDate
            if state.pickingDate {
                state.pickingTime = false
            }
            return state
        }
    }, toggleTime: {
        updateState { state in
            var state = state
            state.pickingTime = !state.pickingTime
            if state.pickingTime {
                state.pickingDate = false
            }
            return state
        }
    }, updateDate: { value in
        updateState { state in
            var state = state
            state.date = value
            return state
        }
    }, apply: { status, duration in
        // A recent or suggested status: set it as it is, like Mattermost's clients do.
        run(MattermostProfile.setCustomStatus(accountId: accountId, emojiName: status.emojiName, text: status.text, duration: duration))
    }, clear: {
        run(MattermostProfile.clearCustomStatus(accountId: accountId))
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get(), MattermostProfile.ownProfileFields(accountId: accountId))
    |> deliverOnMainQueue
    |> map { presentationData, state, fields -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        var entries: [CustomStatusEntry] = []
        let enabled = fields?.customStatusesEnabled ?? true
        entries.append(.header(section: 0, text: strings.Relay_CustomStatus_Header))
        entries.append(.emoji(title: strings.Relay_CustomStatus_Emoji, emoji: MattermostCustomStatus.displayEmoji(name: state.emojiName.isEmpty ? CustomStatusRules.defaultEmoji : state.emojiName)))
        entries.append(.text(placeholder: strings.Relay_CustomStatus_Placeholder, value: state.text, enabled: enabled && !state.busy))
        entries.append(.footer(section: 0, text: enabled ? strings.Relay_CustomStatus_Footer : strings.Relay_CustomStatus_Disabled))
        entries.append(.header(section: 1, text: strings.Relay_CustomStatus_ClearAfter))
        for (index, duration) in CustomStatusDuration.presets.enumerated() {
            entries.append(.duration(index: index, title: MattermostStatusAppearance.customStatusDurationTitle(duration, strings: strings), duration: duration, checked: state.duration == duration))
        }
        entries.append(.duration(index: CustomStatusDuration.presets.count, title: strings.Relay_CustomStatus_Duration_DateAndTime, duration: nil, checked: state.duration == nil))
        if state.duration == nil {
            entries.append(.date(title: strings.Relay_CustomStatus_Ends, date: state.date, pickingDate: state.pickingDate, pickingTime: state.pickingTime))
        }
        let recent = Array(state.recent.prefix(5))
        if !recent.isEmpty {
            entries.append(.header(section: 2, text: strings.Relay_CustomStatus_Recent))
            for (index, status) in recent.enumerated() {
                let duration = CustomStatusDuration(apiValue: status.duration)
                entries.append(.recent(index: index, status: status, label: duration.map { MattermostStatusAppearance.customStatusDurationTitle($0, strings: strings) } ?? ""))
            }
        }
        let suggestions = CustomStatusSuggestion.defaults.filter { suggestion in
            !recent.contains(where: { $0.emojiName == suggestion.emoji && $0.text == suggestion.text })
        }
        if !suggestions.isEmpty {
            entries.append(.header(section: 3, text: strings.Relay_CustomStatus_Suggestions))
            for (index, suggestion) in suggestions.enumerated() {
                let status = MattermostCustomStatus(emojiName: suggestion.emoji, text: suggestion.text, duration: suggestion.duration.apiValue, expiresAt: nil)
                entries.append(.suggestion(index: index, status: status, duration: suggestion.duration, label: MattermostStatusAppearance.customStatusDurationTitle(suggestion.duration, strings: strings)))
            }
        }
        if MattermostProfile.currentOwnStatus(accountId: accountId)?.customStatus != nil {
            entries.append(.clear(title: strings.Relay_CustomStatus_Clear))
        }

        let rightButton: ItemListNavigationButton
        if state.busy {
            rightButton = ItemListNavigationButton(content: .none, style: .activity, enabled: true, action: {})
        } else {
            rightButton = ItemListNavigationButton(content: .text(strings.Relay_CustomStatus_Set), style: .bold, enabled: enabled, action: {
                submit()
            })
        }
        let leftButton = ItemListNavigationButton(content: .text(strings.Common_Cancel), style: .regular, enabled: true, action: {
            dismissImpl?()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.Relay_CustomStatus_Title), leftNavigationButton: leftButton, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: true)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        actionDisposable.dispose()
        recentDisposable.dispose()
    }

    let controller = MattermostDirectoryListController(context: context, state: signal)
    #if DEBUG
    controller.debugName = "custom-status"
    #endif
    controller.navigationPresentation = .modal
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    dismissImpl = { [weak controller] in
        emojiPicker?.dismiss()
        controller?.view.endEditing(true)
        controller?.dismiss()
    }
    emojiSourceView = { [weak controller] in
        guard let controller else {
            return nil
        }
        if let node = controller.itemNode(forTag: MattermostEmojiRowTag()) {
            return node.view
        }
        return controller.view
    }
    #if DEBUG
    controller.debugState = {
        let state = stateValue.with { $0 }
        var duration = "date_and_time"
        if let value = state.duration {
            duration = value.apiValue.isEmpty ? "dont_clear" : value.apiValue
        }
        return ["screen": "custom-status", "emoji": state.emojiName, "text": state.text, "duration": duration, "date": Int(state.date), "recent": state.recent.map { "\($0.emoji) \($0.text) [\($0.duration)]" }, "busy": state.busy, "current": MattermostProfile.currentOwnStatus(accountId: accountId)?.customStatus.map(MattermostStatusAppearance.customStatusText) ?? ""]
    }
    controller.debugActions = [
        "emoji": { command in
            // `value`: an emoji name (as the picker's result would be turned into); the picker closes as after a tap.
            emojiPicker?.dismiss()
            if let value = command["value"] as? String {
                updateState { state in
                    var state = state
                    state.emojiName = value
                    return state
                }
            }
        },
        "pick-emoji": { _ in
            arguments.pickEmoji()
        },
        "text": { command in
            arguments.updateText((command["value"] as? String) ?? "")
        },
        "duration": { command in
            let value = (command["value"] as? String) ?? ""
            if value == "date_and_time" {
                arguments.selectDuration(nil)
                if let minutes = mattermostDebugInt(command, "minutes") {
                    arguments.updateDate(Int32(Date().timeIntervalSince1970) + Int32(minutes * 60))
                }
            } else {
                arguments.selectDuration(CustomStatusDuration(apiValue: value == "dont_clear" ? "" : value) ?? .dontClear)
            }
        },
        "recent": { command in
            let index = mattermostDebugInt(command, "index") ?? 0
            let recent = stateValue.with { $0.recent }
            if index < recent.count {
                arguments.apply(recent[index], CustomStatusDuration(apiValue: recent[index].duration) ?? .dontClear)
            }
        },
        "suggestion": { command in
            let index = mattermostDebugInt(command, "index") ?? 0
            if index < CustomStatusSuggestion.defaults.count {
                let suggestion = CustomStatusSuggestion.defaults[index]
                arguments.apply(MattermostCustomStatus(emojiName: suggestion.emoji, text: suggestion.text, duration: suggestion.duration.apiValue, expiresAt: nil), suggestion.duration)
            }
        },
        "submit": { _ in
            submit()
        },
        "clear": { _ in
            arguments.clear()
        }
    ]
    #endif
    return controller
}
