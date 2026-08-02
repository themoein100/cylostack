//
//  UIImage+Extensions.swift
//  CircleStack
//
//  Created by Moein on 27/07/2026.
//

import UIKit

extension UIImage {
    /// Caps the longest edge, keeping aspect ratio.
    func scaledDown(to maxEdge: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxEdge else { return self }
        let scale = maxEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
