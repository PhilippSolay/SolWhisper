import Foundation

/// Pure computation behind the tray "Input Language" submenu — kept away
/// from NSMenu so the selection/readiness rules are unit-testable.
enum DictationLanguageMenuModel {

    struct Entry: Equatable {
        let id: String
        let title: String
        let isSelected: Bool
        let isReady: Bool
    }

    /// Entries to render: every curated language that's ready on `backend`,
    /// plus the current selection even when it is NOT ready — suffixed with
    /// the readiness hint so the user sees why dictation will refuse to
    /// start instead of the language silently vanishing from the menu.
    static func entries(
        backend: String,
        selectedID: String,
        readiness: (DictationLanguage, String) -> LanguageReadiness = {
            DictationLanguageAvailability.readiness(for: $0, backend: $1)
        }
    ) -> [Entry] {
        DictationLanguage.curated.compactMap { lang in
            let state = readiness(lang, backend)
            let isSelected = lang.id == selectedID
            guard state == .ready || isSelected else { return nil }
            let title = state == .ready
                ? lang.label
                : "\(lang.label) (\(state.hint ?? "unavailable"))"
            return Entry(id: lang.id, title: title,
                         isSelected: isSelected, isReady: state == .ready)
        }
    }
}
