import Foundation

/// Both entry and exit react on the same poll, with no exit-only cooldown.
enum PanelInteraction {
    static let pollInterval: TimeInterval = 0.12
    static let motionDuration: TimeInterval = 0.24
    static let hitSlop: CGFloat = 5
    enum Action: Equatable { case expand, collapse, none }
    static func action(mouse:CGPoint,activation:CGRect,panel:CGRect,expanded:Bool,pinned:Bool,suppressed:Bool) -> Action {
        if activation.contains(mouse) { return !expanded && !suppressed ? .expand : .none }
        if expanded && !pinned && !panel.insetBy(dx:-hitSlop,dy:-hitSlop).contains(mouse) { return .collapse }
        return .none
    }
}
