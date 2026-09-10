//
//  TouchDownButton.swift
//  SwiftUIPlus
//
//  用透明 UIView + 手势承接「按下 / 松开 / 取消」：手指一落下就回调，
//  同时不和外层 ScrollView 的滚动手势互斥。
//  SwiftUI 的 Button / onTapGesture / onLongPressGesture 在 ScrollView 里会先仲裁
//  「这是点击还是滚动」，按下反馈会慢一拍；快点击甚至完全看不到缩放。
//  不要改回 UIButton：UIControl 在 UIScrollView 里默认不能被 touchesShouldCancel 取消，
//  再关掉 delaysContentTouches 之后，从按钮上起手就会把整页滑动吃掉。
//


import SwiftUI
import UIKit

// MARK: - Public API

/// 一层透明的即时触摸热区，专门用来吃「按下 / 松开 / 取消」这三类触摸事件。
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

    /// 本次触摸被取消时执行的回调（对应 UIKit 的 `.touchCancel`，滚动把触摸抢走或位移超过容差时会走到这里）
    public var onTouchCancel: () -> Void

    /// 用四类触摸回调构造一层透明的即时按下热区
    /// - Parameters:
    ///   - onTouchDown: 手指落下时立刻执行
    ///   - onTouchUpInside: 热区内松开时执行
    ///   - onTouchUpOutside: 热区外松开时执行
    ///   - onTouchCancel: 本次触摸被系统取消或被判定为滑动时执行
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

    public func makeUIView(context: Context) -> UIView {
        InstantTouchView()
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        guard let view = uiView as? InstantTouchView else { return }
        view.onTouchDown = onTouchDown
        view.onTouchUpInside = onTouchUpInside
        view.onTouchUpOutside = onTouchUpOutside
        view.onTouchCancel = onTouchCancel
    }
}

public extension View {

    /// 在本视图上叠一层透明 `TouchDownButton`，手指落下立刻回调，松开或取消走对应出口。
    ///
    /// 外层是 `ScrollView` 时，按下变形与页面滑动可以同时成立：手指一落下就缩，
    /// 一旦判定为滑动就走 `onTouchCancel` 并复原，不会把滚动吃掉，也不会在滑完后误点。
    ///
    /// - Parameters:
    ///   - onTouchDown: 手指落下时立刻执行
    ///   - onTouchUpInside: 热区内松开时执行（通常在这里触发业务点击）
    ///   - onTouchUpOutside: 热区外松开时执行
    ///   - onTouchCancel: 本次触摸被系统取消或被判定为滑动时执行
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

/// 透明热区视图：用「保持 possible 的手势」立刻上报按下，同时不和外层滚动手势抢触摸
private final class InstantTouchView: UIView, UIGestureRecognizerDelegate {

    /// 手指落下时执行的最新回调
    var onTouchDown: () -> Void = {}

    /// 热区内松开时执行的最新回调
    var onTouchUpInside: () -> Void = {}

    /// 热区外松开时执行的最新回调
    var onTouchUpOutside: () -> Void = {}

    /// 本次触摸被取消或被判定为滑动时执行的最新回调
    var onTouchCancel: () -> Void = {}

    /// 标记当前是否已经回调过按下、还在等松开或取消
    private var isTracking = false

    /// 本热区自己的即时按下手势，供滑动判定失败时主动收掉
    private let pressGesture = InstantPressGestureRecognizer()

    /// 外层滚动视图的平移手势，滑动开始后用来取消本次按下
    private weak var observedPan: UIPanGestureRecognizer?

    /// 初始化透明热区，并挂上不抢滚动的即时按下手势
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isExclusiveTouch = false
        isMultipleTouchEnabled = false
        pressGesture.owner = self
        pressGesture.delegate = self
        pressGesture.cancelsTouchesInView = false
        pressGesture.delaysTouchesBegan = false
        pressGesture.delaysTouchesEnded = false
        addGestureRecognizer(pressGesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 热区进出窗口时重新挂钩外层滚动手势，离开时拆掉以免残留 target
    override func didMoveToWindow() {
        super.didMoveToWindow()
        detachObservedPan()
        guard window != nil else { return }
        attachEnclosingScrollPan()
    }

    /// 热区释放时拆掉滚动观察，避免滚动视图还握着已销毁对象的 target
    deinit {
        observedPan?.removeTarget(self, action: #selector(handleEnclosingScrollPan(_:)))
    }

    /// 手指刚落下时回调业务，并记下本次触摸已开始跟踪
    func notifyDown() {
        guard isTracking == false else { return }
        isTracking = true
        onTouchDown()
    }

    /// 手指在热区内松开时回调业务；若本次已经被判定为滑动则不再当点击
    func notifyUpInside() {
        guard isTracking else { return }
        isTracking = false
        onTouchUpInside()
    }

    /// 手指滑出热区后松开时回调业务；若本次已经被判定为滑动则不再当滑出
    func notifyUpOutside() {
        guard isTracking else { return }
        isTracking = false
        onTouchUpOutside()
    }

    /// 系统取消触摸或位移超过容差时回调业务，并让按下手势失败以免随后误报点击
    func notifyCancel() {
        guard isTracking else { return }
        isTracking = false
        onTouchCancel()
        pressGesture.failIfPossible()
    }
}

private extension InstantTouchView {

    /// 沿 superview 链找到最近的滚动视图，并观察它的平移手势
    func attachEnclosingScrollPan() {
        var node: UIView? = superview
        while let view = node {
            if let scrollView = view as? UIScrollView {
                let pan = scrollView.panGestureRecognizer
                pan.addTarget(self, action: #selector(handleEnclosingScrollPan(_:)))
                observedPan = pan
                return
            }
            node = view.superview
        }
    }

    /// 拆掉当前观察到的外层滚动手势
    func detachObservedPan() {
        observedPan?.removeTarget(self, action: #selector(handleEnclosingScrollPan(_:)))
        observedPan = nil
    }

    /// 外层滚动视图开始真正平移后取消本次按下，避免滑完松手误触发点击
    @objc func handleEnclosingScrollPan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed:
            let translation = pan.translation(in: pan.view)
            guard hypot(translation.x, translation.y) >= InstantPressGestureRecognizer.moveCancelDistance else { return }
            notifyCancel()
        default:
            break
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension InstantTouchView {

    /// 允许本按下手势与外层 ScrollView 的平移手势同时识别，从而按下变形不挡滑动
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// 手指落下立刻通知 owner，但自身保持 `.possible`，避免把外层滚动手势判失败
private final class InstantPressGestureRecognizer: UIGestureRecognizer {

    /// 窗口坐标位移达到这个距离后，本手势把本次触摸当成滑动而不是点击
    static let moveCancelDistance: CGFloat = 10

    /// 接收按下 / 松开 / 取消通知的热区视图
    weak var owner: InstantTouchView?

    /// 本次触摸开始时落在窗口里的坐标，用来按屏幕位移判断是点还是滑
    private var beganWindowLocation: CGPoint = .zero

    /// 标记本次触摸是否已经因为位移过大而失败
    private var didFailDueToMove = false

    /// 手指落下时立刻通知按下，但保持 `.possible` 不抢滚动
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first else {
            state = .failed
            return
        }
        beganWindowLocation = touch.location(in: nil)
        owner?.notifyDown()
    }

    /// 手指在窗口里移动超过容差后，把本次触摸改判为滑动并取消按下
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard didFailDueToMove == false, let touch = touches.first else { return }
        let now = touch.location(in: nil)
        let distance = hypot(now.x - beganWindowLocation.x, now.y - beganWindowLocation.y)
        guard distance >= Self.moveCancelDistance else { return }
        didFailDueToMove = true
        owner?.notifyCancel()
        state = .failed
    }

    /// 手指抬起且本次仍算点击时，按落点是否还在热区内分发松开回调
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view, let touch = touches.first else {
            owner?.notifyCancel()
            state = .cancelled
            return
        }
        let point = touch.location(in: view)
        if view.bounds.contains(point) {
            owner?.notifyUpInside()
        } else {
            owner?.notifyUpOutside()
        }
        state = .ended
    }

    /// 系统取消本次触摸时通知热区复原
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        owner?.notifyCancel()
        state = .cancelled
    }

    /// 手势复位时清掉本次触摸的窗口起点与滑动失败标记
    override func reset() {
        super.reset()
        beganWindowLocation = .zero
        didFailDueToMove = false
    }

    /// 本次手势还停在 `.possible` 时把它改判失败，阻止随后再走出松开点击
    func failIfPossible() {
        guard state == .possible else { return }
        state = .failed
    }
}
