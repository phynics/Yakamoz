import CoreGraphics

public enum InspectorWidthClamping {
    public static let minWidth: CGFloat = 280

    public static func maxWidth(detailWidth: CGFloat) -> CGFloat {
        max(minWidth, detailWidth * 0.55)
    }

    public static func clamped(_ width: CGFloat, detailWidth: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth(detailWidth: detailWidth))
    }
}
