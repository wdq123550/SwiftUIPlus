//
//  TouchDownButton.swift
//  SwiftUIPlus
//
//  用 UIKit 的 UIButton 承接触摸：手指一落下就回调，松开或被系统取消再走对应出口。
//  SwiftUI 的 Button / onTapGesture / onLongPressGesture 在 ScrollView 里会先仲裁
//  「这是点击还是滚动」，按下反馈会慢一拍；快点击甚至完全看不到缩放。
//  UIButton 的 `.touchDown` 没有这段仲裁，适合「按下立刻缩小、松开立刻复原」。
//

import SwiftUI
import UIKit

// MARK: - Public API

/// 一层透明的 UIKit 按钮，专门用来吃「按下 / 松开 / 取消」这三类即时触摸事件。
///
/// 没有自身尺寸，请作为 `overlay` 盖在已有内容上，或先给它 `.frame`。
/// 便捷写法是直接对内容调 `onTouchDown(...)`。
///
/// ```swift
/// card
///     .scaleEffect(isPressed ? 0.96 : 1)
///     .onTouchDown {
///         isPressed = true
///     } onTouchUpInside: {
///         isPressed = false
///         submit()
///     } onTouchUpOutside: {
///         isPressed = false
///     } onTouchCancel: {
///         isPressed = false
///     }
/// ```
@MainActor
public struct TouchDownButton: UIViewRepresentable {

    /// 手指刚落到热区上时立刻执行的回调（对应 UIKit 的 `.touchDown`）
    public var onTouchDown: () -> Void

    /// 手指仍在热区内松开时执行的回调（对应 UIKit 的 `.touchUpInside`，通常在这里触发业务点击）
    public var onTouchUpInside: () -> Void

    /// 手指滑出热区后松开时执行的回调（对应 UIKit 的 `.touchUpOutside`）
    public var onTouchUpOutside: () -> Void

    /// 系统取消本次触摸时执行的回调（对应 UIKit 的 `.touchCancel`，滚动把触摸抢走时会走到这里）
    public var onTouchCancel: () -> Void

    /// 用四类触摸回调构造一层透明的即时按下按钮
    /// - Parameters:
    ///   - onTouchDown: 手指落下时立刻执行
    ///   - onTouchUpInside: 热区内松开时执行
    ///   - onTouchUpOutside: 热区外松开时执行
    ///   - onTouchCancel: 本次触摸被系统取消时执行
    public init(
        onTouchDown: @escaping () -> Void,
        onTouchUpInside: @escaping () -> Void = {},
        onTouchUpOutside: @escaping () -> Void = {},
        onTouchCancel: @escaping () -> Void = {}
    ) {
        self.onTouchDown = onTouchDown
        self.onTouchUpInside = onTouchUpInside
        self.onTouchUpOutside = onTouchUpOutside
        self.onTouchCancel = onTouchCancel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeUIView(context: Context) -> UIButton {
        let button = TouchDelayExemptButton(type: .custom)
        button.backgroundColor = .clear
        button.isExclusiveTouch = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleDown), for: .touchDown)
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleUpInside), for: .touchUpInside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleUpOutside), for: .touchUpOutside)
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleCancel), for: .touchCancel)
        return button
    }

    public func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.onTouchDown = onTouchDown
        context.coordinator.onTouchUpInside = onTouchUpInside
        context.coordinator.onTouchUpOutside = onTouchUpOutside
        context.coordinator.onTouchCancel = onTouchCancel
    }

    /// 把最新闭包转给 UIButton 的 target-action
    @MainActor
    public final class Coordinator: NSObject {

        /// 手指落下时执行的最新回调
        var onTouchDown: () -> Void = {}

        /// 热区内松开时执行的最新回调
        var onTouchUpInside: () -> Void = {}

        /// 热区外松开时执行的最新回调
        var onTouchUpOutside: () -> Void = {}

        /// 本次触摸被取消时执行的最新回调
        var onTouchCancel: () -> Void = {}

        /// UIButton 在手指落下时回调本方法，立刻转发给业务
        @objc func handleDown() {
            onTouchDown()
        }

        /// UIButton 在热区内松开时回调本方法，立刻转发给业务
        @objc func handleUpInside() {
            onTouchUpInside()
        }

        /// UIButton 在热区外松开时回调本方法，立刻转发给业务
        @objc func handleUpOutside() {
            onTouchUpOutside()
        }

        /// UIButton 在触摸被取消时回调本方法，立刻转发给业务
        @objc func handleCancel() {
            onTouchCancel()
        }
    }
}

public extension View {

    /// 在本视图上叠一层透明 `TouchDownButton`，手指落下立刻回调，松开或取消走对应出口。
    ///
    /// - Parameters:
    ///   - onTouchDown: 手指落下时立刻执行
    ///   - onTouchUpInside: 热区内松开时执行（通常在这里触发业务点击）
    ///   - onTouchUpOutside: 热区外松开时执行
    ///   - onTouchCancel: 本次触摸被系统取消时执行（例如外层 ScrollView 把触摸抢走）
    func onTouchDown(
        _ onTouchDown: @escaping () -> Void,
        onTouchUpInside: @escaping () -> Void = {},
        onTouchUpOutside: @escaping () -> Void = {},
        onTouchCancel: @escaping () -> Void = {}
    ) -> some View {
        overlay {
            TouchDownButton(
                onTouchDown: onTouchDown,
                onTouchUpInside: onTouchUpInside,
                onTouchUpOutside: onTouchUpOutside,
                onTouchCancel: onTouchCancel
            )
        }
    }
}

// MARK: - Internal Implementation

/// 进到窗口后关掉外层 `UIScrollView` 的 `delaysContentTouches`，否则按下仍会被滚动视图扣住一小段。
private final class TouchDelayExemptButton: UIButton {

    /// 按钮挂上窗口后沿父链找到外层滚动视图，并关掉它对内容触摸的延迟
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        disableEnclosingScrollViewTouchDelay()
    }

    /// 沿 superview 链找到最近的 `UIScrollView`，并把它的内容触摸延迟关掉
    private func disableEnclosingScrollViewTouchDelay() {
        var node: UIView? = superview
        while let view = node {
            if let scrollView = view as? UIScrollView {
                scrollView.delaysContentTouches = false
                return
            }
            node = view.superview
        }
    }
}
