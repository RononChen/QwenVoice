import Foundation

enum ActivityPresentation: Equatable {
    case inlinePlayer
    case standaloneCard
}

struct ActivityStatus: Equatable {
    let label: String
    let fraction: Double?
    let presentation: ActivityPresentation
}

enum SidebarStatus: Equatable {
    case idle
    /// XPC is up but no model weights are resident (idle-unload / cold).
    case standby
    case starting
    case running(ActivityStatus)
    case error(String)
    case crashed(String)
}
