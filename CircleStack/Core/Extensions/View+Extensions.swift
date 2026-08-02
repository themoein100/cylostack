//
//  View+Extensions.swift
//  CircleStack
//
//  Created by Moein on 28/07/2026.
//

import SwiftUI

extension View {
    /// Locks scroll bounce behavior when content fits on screen (iOS 16.4+).
    @ViewBuilder
    func applyScrollBounceBehavior() -> some View {
        if #available(iOS 16.4, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}
