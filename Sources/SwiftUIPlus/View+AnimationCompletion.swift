//
//  View+AnimationCompletion.swift
//  SwiftUIPlus
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  【给后续 AI / 维护者】何时用本文件、绝不要再用 withAnimation completion 做业务
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
//  ## 问题是什么
//
//  系统 API：
//      withAnimation(...) { 改状态 } completion: { 做业务 }
//  以及 iOS 17 的：
//      withAnimation(..., completionCriteria: .logicallyComplete / .removed) { } completion: { }
//
//  这里的 completion **挂在动画事务（Transaction）上**，不是挂在「某一层 View 真正画完」上。
//  文档虽写「保证回调一次」，完成标准仍是事务语义（logicallyComplete / removed），
//  **不是**「跟某 View 的 animatableData 渲染进度走」。
//
//  ## 真实故障长什么样（FurFriends 识别解锁弹窗，2026-08）
//
//  场景：识别页看完激励广告（含金手指秒跳）→ 同一拍里：
//    1) 识别结果页从锁定态大变样成正式结果（requestStatus = .return，整页重建）
//    2) PopupPresenter 用 withAnimation 弹出奖励框
//  弹窗与识别页在同一棵 SwiftUI 树（MainView 上的 overlay），共享同一次刷新。
//
//  现象：
//    - 奖励弹窗已经出现在屏幕上
//    - 但 appearCallBack 不来 → 抽奖券 bar / 飞入动画 / canClose 全不启动
//    - 点 Got it! / 关闭按钮没反应（业务门闩还没打开）
//    - 再点一下屏幕，completion 才补调，一切突然正常
//
//  根因：同拍大重建可能在原动画事务之外重新提交终点状态，把在飞动画掐断；
//  动画「不算逻辑完成」→ completion 不结算 → 挂在上面的业务停摆。
//  参考：https://fatbobman.com/posts/debugging-notes-on-two-swiftui-animation-bugs/
//  （Bug 1：显式 withAnimation 被父视图重建打断；改用隐式 .animation + Animatable 收尾）
//
//  ## 错误替代方案（不要用）
//
//  1. Task.sleep / asyncAfter(动画时长)
//     → 挂钟计时。主线程被 WebView / H5 SDK 拖卡时，时间到了画面还没画完，
//       回调会提前打出（弹窗内飞行起点未上报 → 飞入动画被 guard 掉）。
//  2. 在 onAppear 里立刻 startAppearFlow
//     → 破坏「展示动画结束后才回调」的语义，飞券会和入场动画抢。
//  3. 做成全局自由函数伪装 withAnimation { } completion:
//     → 完成信号必须挂在视图树上；自由函数挂不进树，救不了事务被掐断。
//  4. 指望 SwiftUIX
//     → 查过源码：没有稳妥的动画完成 API（withAnimation+ 只是延迟执行）。
//
//  ## 正确做法（本文件）
//
//  1. 动画用隐式 `.animation(_:value:)` 声明在**动画真正发生的那层常驻 View** 上，
//     不要用 withAnimation 包一层全局事务（动画归属到本层，少被外部重建牵连）。
//  2. 完成信号用 Animatable 观察器盯 animatableData 是否到终点（跟渲染走）：
//     - 动画被掐断、直接跳终点 → 立刻收到终值并回调（不挂死）
//     - 主线程卡顿 → 跟着帧变慢（只会晚，不会早）
//  3. 业务上「必须发生」的事（发奖、开按钮、弹窗队列推进、appearCallBack）
//     只许挂本文件的回调；系统 completion 只许做纯装饰收尾。
//
//  ## API 怎么选
//
//  - 触发值 == 观察值（每次 token += 1）：用 `stableAnimation(_:value:onComplete:)`
//  - 一条曲线 + 多个独立进度（弹窗出场 / 退场各一个 progress）：
//      .onAnimationCompleted(for: appearProgress) { ... }
//      .onAnimationCompleted(for: dismissProgress) { ... }
//      .animation(activeAnimation, value: animationToken)
//
//  ## 硬规则（违反 = 立刻误报完成）
//
//  1. 观察器挂在**常驻**视图上，不能随被观察内容一起插入/移除
//  2. 观察器必须在 `.animation(_:value:)` 的**内侧**（上游）
//  3. 回调里用 DispatchQueue.main.async 派到下一拍（已在实现里写死）；
//     不要改成 MainActor.run / Task { @MainActor }——渲染周期内可能同步执行或调度时机不对
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
