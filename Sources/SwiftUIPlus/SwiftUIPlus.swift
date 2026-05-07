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
    ///   - onDestroy: 仅在视图真正从导航栈 Pop 或被 Dismiss 销毁时触发
    ///   - onEvent: 原始生命周期事件回调，用于更精细的控制
    @MainActor
    func onLifecycle(
        onAppear: (@MainActor @Sendable () -> Void)? = nil,
        onDisappear: (@MainActor @Sendable () -> Void)? = nil,
        onDestroy: (@MainActor @Sendable () -> Void)? = nil,
        onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)? = nil
    ) -> some View {
        self.background(
            LifecycleBridgeView(onEvent: { event in
                // 在主线程执行回调
                onEvent?(event)
                
                switch event {
                case .viewDidAppear:
                    onAppear?()
                case .viewDidDisappear(let isRemoving):
                    onDisappear?()
                    if isRemoving {
                        onDestroy?()
                    }
                default:
                    break
                }
            })
            .accessibilityHidden(true)
        )
    }
}

// MARK: - Internal Implementation

/// 底层桥接容器
@MainActor
private struct LifecycleBridgeView: UIViewControllerRepresentable {
    /// 这里的闭包类型必须与 View 扩展中的定义严格一致，包含 @MainActor 和 @Sendable
    let onEvent: @MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void

    /// 协调器：标记为 @MainActor 确保与 UI 生命周期对齐
    @MainActor
    final class Coordinator {
        var onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> LifecycleSpyViewController {
        let controller = LifecycleSpyViewController()
        controller.onEvent = { [weak coordinator = context.coordinator] event in
            // SpyViewController 会在主线程触发，通知 Coordinator
            coordinator?.onEvent?(event)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: LifecycleSpyViewController, context: Context) {
        context.coordinator.onEvent = onEvent
    }
}

/// 真正的 UIKit 间谍
private final class LifecycleSpyViewController: UIViewController {
    /// 注意：这里的回调也要保持一致
    var onEvent: (@MainActor @Sendable (SwiftUIPlusLifecycleEvent) -> Void)?

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
        let isRemoving = isMovingFromParent || isBeingDismissed
        onEvent?(.viewWillDisappear(isRemoving: isRemoving))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let isRemoving = isMovingFromParent || isBeingDismissed
        onEvent?(.viewDidDisappear(isRemoving: isRemoving))
    }
}
