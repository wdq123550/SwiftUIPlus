import SwiftUI
import UIKit

// MARK: Public API

/// 定义视图生命周期的事件类型
public enum SwiftUIPlusLifecycleEvent: Sendable {
    /// 视图首次加载（对应 UIKit 的 `viewDidLoad`）
    case viewDidLoad
    /// 视图即将出现（对应 UIKit 的 `viewWillAppear`）
    case viewWillAppear
    /// 视图已经出现（对应 UIKit 的 `viewDidAppear`，每次重新可见都会触发）
    case viewDidAppear
    /// 视图即将消失（对应 UIKit 的 `viewWillDisappear`），`isRemoving` 表示是否正在被销毁
    case viewWillDisappear(isRemoving: Bool)
    /// 视图已经消失（对应 UIKit 的 `viewDidDisappear`），`isRemoving` 表示是否正在被销毁
    case viewDidDisappear(isRemoving: Bool)
}

public extension View {
    /// 视图显示时触发（对应 UIKit 的 `viewDidAppear`，每次重新可见都会触发，不仅仅是首次）
    @MainActor
    func onLifecycleAppear(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        attachLifecycle(
            onEvent: { event in
                if case .viewDidAppear = event { action() }
            }
        )
    }

    /// 视图消失时触发（对应 UIKit 的 `viewDidDisappear`，包含被覆盖或被销毁两种情况）
    @MainActor
    func onLifecycleDisappear(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        attachLifecycle(
            onEvent: { event in
                if case .viewDidDisappear = event { action() }
            }
        )
    }

    /// 视图真正被销毁时触发（NavigationStack pop / sheet dismiss / 条件切换等）
    /// 注意：这是「SwiftUI 把视图从层级拆除」的信号，在 List / LazyVStack 中可能由 cell 复用触发。
    @MainActor
    func onLifecycleDestroy(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> some View {
        attachLifecycle(onDestroy: action)
    }

    /// 监听原始的生命周期事件，可用于更精细的控制（同一视图建议复用此 API,避免多个 bridge 叠加）
    @MainActor
    func onLifecycleEvent(
        _ action: @escaping @MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void
    ) -> some View {
        attachLifecycle(onEvent: action)
    }

    /// 视图仅在「首次出现」时执行一次 action（参照 SwiftUIX 的 onAppearOnce 实现）
    /// 与系统 `onAppear` 的区别：系统 `onAppear` 每次重新可见都会触发,此方法通过内联 `@State` 记录标志位,保证 action 只执行一次
    @MainActor
    func onAppearOnce(perform action: @escaping () -> Void) -> some View {
        // 用一个持有 @State 的内联包装视图承载「是否已出现」的标志位,SwiftUIX 借助 withInlineState 达到同样效果
        InlineAppearOnceView(content: self, action: action)
    }
}

// MARK: Internal Helpers

private extension View {
    /// 在视图背景挂载一个不可见、不参与命中测试的桥接视图,用来转发生命周期
    @MainActor
    func attachLifecycle(
        onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)? = nil,
        onDestroy: (@MainActor @Sendable () -> Void)? = nil
    ) -> some View {
        self.background {
            LifecycleBridgeView(onEvent: onEvent, onDestroy: onDestroy)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Internal Implementation

/// onAppearOnce 的内联状态包装视图：用 @State 记录标志位,确保 action 仅在首次出现时执行一次
@MainActor
private struct InlineAppearOnceView<Content: View>: View {
    /// 被包装的原始视图
    let content: Content
    /// 首次出现时执行的回调
    let action: () -> Void
    /// 标记视图是否已经出现过,避免重复执行 action
    @State private var didAppear = false

    var body: some View {
        content.onAppear {
            // 已经出现过则直接返回,不再执行 action
            guard !didAppear else { return }
            action()
            didAppear = true
        }
    }
}

/// 底层桥接容器
@MainActor
private struct LifecycleBridgeView: UIViewControllerRepresentable {
    /// 普通事件回调
    let onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?
    /// 销毁回调（由 `dismantleUIViewController` 触发）
    let onDestroy: (@MainActor @Sendable () -> Void)?

    /// 协调器：标记为 @MainActor 确保与 UI 生命周期对齐
    @MainActor
    final class Coordinator {

        // MARK: - Stored properties

        /// 最新的事件回调,由 update 阶段刷新
        var onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?
        /// 最新的销毁回调,由 update 阶段刷新
        var onDestroy: (@MainActor @Sendable () -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> LifecycleSpyViewController {
        // 在 make 阶段就同步注入一次 closure,避免极端情况下 viewDidLoad 早于 update 调用导致首个事件丢失
        context.coordinator.onEvent = onEvent
        context.coordinator.onDestroy = onDestroy
        let controller = LifecycleSpyViewController()
        controller.onEvent = { [weak coordinator = context.coordinator] event in
            coordinator?.onEvent?(event)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: LifecycleSpyViewController, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.onDestroy = onDestroy
    }

    /// SwiftUI 把桥接视图从层级中移除时调用,是「视图被销毁」最权威的信号:
    /// 覆盖 NavigationStack pop、sheet dismiss、if 条件切换等所有场景。
    static func dismantleUIViewController(_ uiViewController: LifecycleSpyViewController, coordinator: Coordinator) {
        // SwiftUI 绝大多数场景下会在主线程调用 dismantle,但 Apple 并未强保证。
        // 这里做一层兜底:在主线程同步执行,非主线程则异步派发,避免 `assumeIsolated` 触发崩溃。
        let fire: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                coordinator.onDestroy?()
                coordinator.onDestroy = nil
                coordinator.onEvent = nil
            }
        }
        if Thread.isMainThread {
            fire()
        } else {
            DispatchQueue.main.async(execute: fire)
        }
    }
}

/// 真正的 UIKit 间谍
private final class LifecycleSpyViewController: UIViewController {
    /// 事件回调,由 representable 在 make/update 阶段写入
    var onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?

    /// isMovingFromParent / isBeingDismissed 在 viewDidDisappear 时已被 UIKit 重置,
    /// 必须在 viewWillDisappear 阶段提前捕获。
    /// 同时由于本 VC 是 UIHostingController 的子 VC,需向上检查 parent 的状态。
    private var pendingIsRemoving = false

    /// 向上递归判断当前 VC(或祖先)是否正在从导航栈/容器中移除
    private var isBeingRemovedFromStack: Bool {
        var vc: UIViewController? = self
        while let current = vc {
            if current.isMovingFromParent || current.isBeingDismissed {
                return true
            }
            vc = current.parent
        }
        return false
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        onEvent?(.viewDidLoad)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        onEvent?(.viewWillAppear)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onEvent?(.viewDidAppear)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 只做单向提升:一旦确认在移除流程中,后续连续的 willDisappear 不能把它覆盖回 false
        // (例如 sheet 之上再 push、跨场景切换等边界场景下可能连续触发 willDisappear)
        if isBeingRemovedFromStack { pendingIsRemoving = true }
        onEvent?(.viewWillDisappear(isRemoving: pendingIsRemoving))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 取出当前状态后立即 reset,为下一轮 disappear 周期复位
        let removing = pendingIsRemoving
        pendingIsRemoving = false
        onEvent?(.viewDidDisappear(isRemoving: removing))
    }
}
