import SwiftUI

/// The dismiss control of a sheet's navigation bar. On iOS 26 it is the
/// system close button (`Button(role: .close)` — an xmark in a glass
/// circle); before that a "Close" text button. Place it with
/// `ToolbarItem(placement: .cancellationAction)`.
///
/// Use it for sheets that only show something (details, explanations).
/// Forms that collect input keep explicit Cancel / Save buttons.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
        } else {
            Button(String(localized: "common.close"), action: action)
        }
    }
}
