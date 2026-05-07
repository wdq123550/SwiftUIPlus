import SwiftUI
import UIKit

// MARK: - Public API

/// 定义视图生命周期的事件类型
public enum SwiftUIPlusLifecycleEvent: Sendable {
    case viewDidLoad
    case viewWillAppear
    case viewDidAppear
    case viewWillDisappear(isRemoving: Bool)
    case viewDidDisappear(isRemoving: Bool)
}

public extension View {
    /// 监听 SwiftUI 视图对应的底层 UIKit 生命周期
    /// - Parameters:
    ///   - onAppear: 视图显示时触发（对应 viewDidAppear）
    ///   - onDisappear: 视图消失时触发（对应 viewDidDisappear，包含被覆盖或被销毁）
    ///   - onDestroy: 仅在视图真正从导航栈 Pop / 被 Dismiss / 条件切换销毁时触发
    ///   - onEvent: 原始生命周期事件回调，用于更精细的控制
    @MainActor
    func onLifecycle(
        onAppear: (@MainActor @Sendable () -> Void)? = nil,
        onDisappear: (@MainActor @Sendable () -> Void)? = nil,
        onDestroy: (@MainActor @Sendable () -> Void)? = nil,
        onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)? = nil
    ) -> some View {
        self.background(
            LifecycleBridgeView(
                onEvent: { event in
                    onEvent?(event)
                    switch event {
                    case .viewDidAppear:
                        onAppear?()
                    case .viewDidDisappear:
                        onDisappear?()
                    default:
                        break
                    }
                },
                onDestroy: {
                    onDestroy?()
                }
            )
            .accessibilityHidden(true)
        )
    }
}

// MARK: - Internal Implementation

/// 底层桥接容器
@MainActor
private struct LifecycleBridgeView: UIViewControllerRepresentable {
    let onEvent: @MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void
    let onDestroy: @MainActor @Sendable () -> Void

    /// 协调器：标记为 @MainActor 确保与 UI 生命周期对齐
    @MainActor
    final class Coordinator {
        var onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?
        var onDestroy: (@MainActor @Sendable () -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> LifecycleSpyViewController {
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

    /// SwiftUI 把桥接视图从层级中移除时调用，这是「视图被销毁」最权威的信号：
    /// 覆盖 NavigationStack pop、sheet dismiss、if 条件切换等所有场景。
    static func dismantleUIViewController(_ uiViewController: LifecycleSpyViewController, coordinator: Coordinator) {
        MainActor.assumeIsolated {
            coordinator.onDestroy?()
            coordinator.onDestroy = nil
            coordinator.onEvent = nil
        }
    }
}

/// 真正的 UIKit 间谍
private final class LifecycleSpyViewController: UIViewController {
    var onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?

    /// isMovingFromParent / isBeingDismissed 在 viewDidDisappear 时已被 UIKit 重置，
    /// 必须在 viewWillDisappear 阶段提前捕获。
    /// 同时由于本 VC 是 UIHostingController 的子 VC，需向上检查 parent 的状态。
    private var pendingIsRemoving = false

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
        pendingIsRemoving = isBeingRemovedFromStack
        onEvent?(.viewWillDisappear(isRemoving: pendingIsRemoving))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onEvent?(.viewDidDisappear(isRemoving: pendingIsRemoving))
    }
}
