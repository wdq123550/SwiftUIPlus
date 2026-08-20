//
//  View+ShrinkToFit.swift
//  SwiftUIPlus
//
//  「整块内容超宽就等比缩小」：先按理想尺寸排开，量出需求尺寸后整块乘一个缩放比。
//
//  为什么不用 minimumScaleFactor：
//  它是 Text 专属的排版特性，图标 / 形状根本不认识它；而且它是**每个 Text 各自**算缩放比的。
//  于是 `HStack { 图标; 文案; 图标; 数字 }` 这种图文混排一超宽就会翻车：容器把可用宽度分摊给各段，
//  长文案分到的份额少、被缩得很狠，短数字分到的够用、几乎不缩，同一行里出现两种字号，图标还是原大小。
//  本修饰符改成对整块做渲染变换，字号、图标、段间距同比缩小，观感等于「这块内容被整体缩小」。
//

import SwiftUI

// MARK: - Public API

public extension View {

    /// 内容超出给定尺寸时，把**整块内容**等比缩小到刚好装下；没超出则原样显示（只缩不放）。
    ///
    /// 典型场景是图文混排且文案长度不可控（多语言按钮、带图标的标签）：
    ///
    /// ```swift
    /// HStack(spacing: 2) {
    ///     Image(uiImage: adIcon)
    ///     Text("Earn")
    ///     Image(uiImage: coinIcon)
    ///     Text("1000")
    /// }
    /// .shrinkToFit(maxWidth: 200)
    /// ```
    ///
    /// 缩放是渲染变换，所以图标与子视图间距会跟文字一起等比缩小，各部分的比例关系保持不变。
    /// 修饰后视图对外的布局尺寸即**缩放后**的尺寸，可以放心塞进 `HStack` / `VStack` 参与排布。
    ///
    /// - Important: 内部会对内容加 `fixedSize()`，因为只有不受父层约束地排一次，量到的才是「需求尺寸」，
    ///   比值才有意义。也因此内容里**不要**再依赖父层给的宽度做自适应（如内部的 `Spacer`、
    ///   `frame(maxWidth: .infinity)`），那些会因为 `fixedSize` 失去意义。
    /// - Note: 首帧尚未量到尺寸，按原大小绘制，量到后触发一次重绘才带上缩放；正常不需要缩放的内容
    ///   两趟结果一致，看不出差别。
    /// - Note: 文字是被变换缩小的，不是按更小字号重排，缩放比很低（约 0.5 以下）时会略微发虚。
    ///   位图切图只缩不放属于降采样，不受影响。
    /// - Parameters:
    ///   - maxWidth: 允许占用的最大宽度；传 `nil` 表示不限制宽度
    ///   - maxHeight: 允许占用的最大高度；传 `nil` 表示不限制高度
    func shrinkToFit(maxWidth: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        modifier(ShrinkToFitModifier(maxWidth: maxWidth, maxHeight: maxHeight))
    }
}

// MARK: - ShrinkToFitModifier

/// 把内容整块等比缩小到给定尺寸以内的修饰符。
///
/// 三步走：`fixedSize` 排出需求尺寸 → `onGeometryChange` 量到它 → `scaleEffect` 整块缩放。
/// 不存在测量回环：`scaleEffect` 只是渲染变换、不参与布局，而 `fixedSize` 会忽略父层提议，
/// 所以最外层补的 frame 改不动量到的需求尺寸。
private struct ShrinkToFitModifier: ViewModifier {

    /// 允许占用的最大宽度（nil 表示宽度不限）
    let maxWidth: CGFloat?

    /// 允许占用的最大高度（nil 表示高度不限）
    let maxHeight: CGFloat?

    /// 内容按理想尺寸排开后的需求尺寸（由 onGeometryChange 上报；未量到时为 .zero）
    @State private var contentSize: CGSize = .zero

    /// 渲染流程：先按需求尺寸排开并量出来，再整块缩放，最后把布局尺寸补成缩放后的尺寸
    func body(content: Content) -> some View {
        let scale = resolvedScale
        content
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                guard size != contentSize else { return }
                contentSize = size
            }
            .scaleEffect(scale)
            // 未量到尺寸时两个维度都传 nil，等于不干预布局；量到后对外报缩放后的尺寸，
            // 免得父容器仍按缩放前的大小给它留位置
            .frame(width: layoutLength(contentSize.width, scale: scale),
                   height: layoutLength(contentSize.height, scale: scale))
    }

    /// 本次该用的缩放比：宽高各自算一个，取最小的那个，且不超过 1（只缩不放）
    private var resolvedScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        var scale: CGFloat = 1
        if let maxWidth, maxWidth > 0 {
            scale = min(scale, maxWidth / contentSize.width)
        }
        if let maxHeight, maxHeight > 0 {
            scale = min(scale, maxHeight / contentSize.height)
        }
        return scale
    }

    /// 把某个维度的需求长度换算成对外声明的布局长度；还没量到（0）时返回 nil 表示这一维不干预
    private func layoutLength(_ length: CGFloat, scale: CGFloat) -> CGFloat? {
        length > 0 ? length * scale : nil
    }
}
