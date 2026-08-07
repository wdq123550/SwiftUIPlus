//
//  View+AnimationCompletion.swift
//  SwiftUIPlus
//
//  稳妥的「动画真正画完」回调：跟随 SwiftUI 渲染时钟插值，而不是 withAnimation 的 completion 事务。
//
//  为什么不直接用 withAnimation(_:completion:)：
//  那个 completion 挂在动画事务上；业务页面同拍大重建时，SwiftUI 可能掐断在飞动画，
//  completion 迟迟不结算，把发奖 / 开按钮 / 弹窗队列等业务一起拖死。
//  本文件的观察器盯的是 animatableData 是否已经推到终点——动画被掐断跳终点时也会立刻回调，
//  主线程卡顿时跟着帧变慢，只会晚、不会早。
//

import SwiftUI

// MARK: - Public API

public extension View {

    /// 当 `value` 的动画插值到达终点时回调。
    ///
    /// 用法（两件套，缺一不可）：
    /// 1. 把本修饰符挂在**常驻**视图上（不要挂在会随内容一起插入/移除的那一层）；
    /// 2. 在外侧（更靠外）再挂 `.animation(_:value:)`，让 `value` 的变化被插值。
    ///
    /// ```swift
    /// content
    ///     .onAnimationCompleted(for: progress) {
    ///         // 真画完了
    ///     }
    ///     .animation(animation, value: token)
    /// ```
    ///
    /// - Important: 观察器必须落在 `.animation` 的**内侧**（上游）。挂到外侧时 `value`
    ///   不会被插值，会一步跳到终值并立刻误报完成。
    /// - Parameters:
    ///   - value: 正在被动画驱动、可插值的值（如 `CGFloat` 进度、`Double` 偏移）
    ///   - completion: 插值到达终点时的回调（经主运行循环下一拍派发，避免在视图更新中改状态）
    func onAnimationCompleted<Value: VectorArithmetic & Equatable>(
        for value: Value,
        completion: @escaping () -> Void
    ) -> some View {
        modifier(AnimationCompletionObserver(observedValue: value, onFinished: completion))
    }

    /// 用隐式动画驱动 `value` 变化，并在动画真正画到终点时回调。
    ///
    /// 等价于把 `onAnimationCompleted` 正确叠在 `.animation` 内侧，适合「触发值」和
    /// 「观察值」是同一个数的场景（例如每次 `token += 1`）：
    ///
    /// ```swift
    /// content
    ///     .stableAnimation(.easeInOut(duration: 0.25), value: token) {
    ///         // token 这一轮动画画完了
    ///     }
    /// ```
    ///
    /// 若需要「一条动画曲线 + 多个独立进度」（例如弹窗出场 / 退场各盯一个 progress），
    /// 请手动组合：多个 `onAnimationCompleted(for:)` + 一条 `.animation(_:value: token)`。
    ///
    /// - Parameters:
    ///   - animation: 本轮使用的动画曲线；传 `nil` 表示无动画（`value` 变化时仍会走到终点并回调）
    ///   - value: 既触发隐式动画、又被观察是否到达终点的值
    ///   - onComplete: 插值到达终点时的回调
    func stableAnimation<Value: VectorArithmetic & Equatable>(
        _ animation: Animation?,
        value: Value,
        onComplete: @escaping () -> Void
    ) -> some View {
        self
            .onAnimationCompleted(for: value, completion: onComplete)
            .animation(animation, value: value)
    }
}

// MARK: - AnimationCompletionObserver

/// 「动画真的画完了」的观察器：跟随 SwiftUI 的渲染时钟，而不是挂钟计时。
///
/// 原理：SwiftUI 在动画的每一帧把 `animatableData` 往目标值推进，并在画到终态那一帧把它设成
/// 目标值。帧由渲染驱动，所以这个信号同时避开了另外两种写法各自的坑：
/// - `Task.sleep` / `asyncAfter` 按动画时长计时：主线程卡顿时时间到了画面却还没画完，回调会提前
///   打出去。观察器卡顿时跟着一起卡，只会晚、不会早。
/// - `withAnimation(_:completion:)` 的 completion：动画被外部重建掐断后它可能不结算，会一直挂着
///   不回调。观察器即便在「动画被掐断、直接跳终态」时也会立刻收到一次终值，因此绝不会挂死。
///
/// 用法上有两条硬要求，违反任意一条都会退化成「立刻误报完成」：
/// 1. 必须挂在**常驻**视图上，不能随被观察的内容一起插入 / 移除——新挂载的实例首帧就等于目标值，
///    等不到动画；
/// 2. 必须落在驱动动画的 `.animation(_:value:)` 的**内侧**（上游），否则进度值不被插值，会一步
///    跳到终值。
private struct AnimationCompletionObserver<Value: VectorArithmetic & Equatable>: ViewModifier, Animatable {

    /// SwiftUI 逐帧推进的动画值；等于 `targetValue` 即代表已画到终态
    var animatableData: Value {
        didSet { notifyIfFinished() }
    }

    /// 本次动画的目标值（构造时固定，不参与插值）
    private let targetValue: Value

    /// 画到终态时的回调
    private let onFinished: () -> Void

    /// 初始化：传入当前要观察的值与动画结束回调
    init(observedValue: Value, onFinished: @escaping () -> Void) {
        self.animatableData = observedValue
        self.targetValue = observedValue
        self.onFinished = onFinished
    }

    /// 本观察器不改变视图外观，原样透传
    func body(content: Content) -> some View {
        content
    }

    /// 推进到终态才回调；派发到下一个主线程周期，避免在视图更新过程中直接改状态。
    ///
    /// 这里刻意用 `DispatchQueue.main.async`，不要「顺手」换成 Swift Concurrency：本方法是在
    /// SwiftUI 的渲染 / 布局周期内部被调用的，`MainActor.run` 在已处于主线程时可能同步执行、
    /// 跳不出当前计算周期，`Task { @MainActor in }` 走协作式调度、落点由 executor 决定，
    /// 都不保证是主运行循环的下一拍。而我们要的正是「明确推迟到下一拍」，以稳妥避开
    /// Publishing changes from within view updates 警告。
    private func notifyIfFinished() {
        guard animatableData == targetValue else { return }
        let callback = onFinished
        DispatchQueue.main.async {
            callback()
        }
    }
}
