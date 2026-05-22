# SwiftUIPlus

一个轻量的 SwiftUI 生命周期补全库，桥接到 UIKit 的真实 `UIViewController` 生命周期，
提供 `viewDidLoad / viewWillAppear / viewDidAppear / viewWillDisappear / viewDidDisappear`
以及 SwiftUI 原生缺失的「视图真正被销毁」回调。

- 最低支持：**iOS 17**
- 仅依赖 `SwiftUI` + `UIKit`，零第三方依赖
- 全 `@MainActor`，Swift 并发友好

---

## 安装

Swift Package Manager：

```swift
.package(url: "https://github.com/wdq123550/SwiftUIPlus.git", from: "0.1.0")
```

然后在 target 里依赖：

```swift
.product(name: "SwiftUIPlus", package: "SwiftUIPlus")
```

---

## 快速开始

```swift
import SwiftUI
import SwiftUIPlus

struct DemoView: View {
    var body: some View {
        Text("Hello")
            .onLifecycleAppear {
                print("视图出现（每次重新可见都会触发）")
            }
            .onLifecycleDisappear {
                print("视图消失（被覆盖或被销毁都会触发）")
            }
            .onLifecycleDestroy {
                print("视图被销毁（pop / dismiss / if 切换等）")
            }
    }
}
```

需要更细粒度的事件，可以用 `onLifecycleEvent`：

```swift
SomeView()
    .onLifecycleEvent { event in
        switch event {
        case .viewDidLoad:                     break
        case .viewWillAppear:                  break
        case .viewDidAppear:                   break
        case .viewWillDisappear(let isRemoving): break
        case .viewDidDisappear(let isRemoving):  break
        }
    }
```

> 性能小建议：同一视图需要监听多种事件时，**优先使用一个 `onLifecycleEvent`**，
> 避免多个修饰符叠加产生多个桥接 `UIViewController`。

---

## API 一览

| API | 触发时机 | 说明 |
|---|---|---|
| `onLifecycleAppear { }` | `viewDidAppear` | 每次重新可见都会触发，**不仅仅是首次** |
| `onLifecycleDisappear { }` | `viewDidDisappear` | 被覆盖或被销毁都会触发 |
| `onLifecycleDestroy { }` | `dismantleUIViewController` | SwiftUI 把视图从层级中拆除时触发 |
| `onLifecycleEvent { event in }` | 全部事件 | 适合需要多事件 / 需要 `isRemoving` 标记的场景 |

`SwiftUIPlusLifecycleEvent` 定义：

```swift
public enum SwiftUIPlusLifecycleEvent: Sendable {
    case viewDidLoad
    case viewWillAppear
    case viewDidAppear
    case viewWillDisappear(isRemoving: Bool)
    case viewDidDisappear(isRemoving: Bool)
}
```

`isRemoving` 语义：UIKit 层判断当前 VC（或祖先）是否正在 `isMovingFromParent / isBeingDismissed`。
**只能用作 UIKit 容器层面的"被移除"参考，不能作为"业务对象被销毁"的权威信号**——
要判断后者请用 `onLifecycleDestroy`。

---

## 实现原理

在视图 `.background` 中挂载一个不可见、不参与命中测试的桥接 `UIViewController`
（`UIViewControllerRepresentable`），把 UIKit 的生命周期事件原样转发给 SwiftUI。

「视图被销毁」用 SwiftUI 的 `dismantleUIViewController` 静态方法捕获，
这是目前 SwiftUI 体系内最权威的"视图退出层级"信号，覆盖：

- NavigationStack pop
- sheet / fullScreenCover dismiss
- `if condition` 切换为 false
- `ForEach` 中某个 id 被移除
- 父视图整体被销毁

---

## 已知边界（请务必阅读）

下列场景属于 SwiftUI 自身的行为特征，**本库无法绕过**，使用前请知悉：

### 1. SwiftUI structural identity 复用可能不触发 `onDestroy`

如果 `if-else` 两个分支结构高度相似，SwiftUI 可能复用同一个 hosting，
只调用 `update` 而不 `dismantle`：

```swift
if condition {
    SomeView().onLifecycleDestroy { print("A") }
} else {
    SomeView().onLifecycleDestroy { print("B") }   // 切换时未必触发
}
```

**解决办法**：在容易复用的分支上加 `.id(...)` 强制断开 identity。

### 2. `List` / `LazyVStack` / `LazyHGrid` 的 cell 复用会触发 `onDestroy`

当 cell 滚出屏幕被回收时，SwiftUI 会 dismantle 它内部的 representable，
此时 `onDestroy` 会被触发，但**业务数据源里这条数据并没有被删除**。

请把 `onLifecycleDestroy` 理解为「SwiftUI 把这个视图从层级拆掉了」，
而不是「这条数据被删除了」。需要后者请监听数据源本身的变化。

### 3. NavigationStack（iOS 16+）pop 时 `onDestroy` 有延迟

NavigationStack 底层是 `UINavigationController`，pop 动画**结束后**才会执行 dismantle。
如果需要"开始 pop 的瞬间"就响应，请用 `onLifecycleDisappear` + `isRemoving` 判断。

### 4. TabView 切 tab 不会卸载隐藏 tab

iOS 16+ 的 TabView 默认会保留所有 tab 的 hosting，
切到另一个 tab 时**不会**触发当前 tab 的 `onDestroy`，只会触发 `onLifecycleDisappear`。

### 5. App 被杀进程时不一定触发 `onDestroy`

`dismantleUIViewController` 在 app 被强杀的瞬间不保证能跑完。
需要持久化的清理逻辑请放在 `scenePhase` 切到 `background` 时执行，
**不要**完全依赖 `onLifecycleDestroy`。

### 6. App 切后台不等于 `viewDidDisappear`

`@Environment(\.scenePhase)` 才是前后台切换的权威来源。
本库只反映 UIKit 真实的 VC 生命周期，**不模拟 scene phase**。

### 7. `onLifecycleAppear` 不是「首次出现」

它对应 UIKit 的 `viewDidAppear`，从其它界面返回也会再次触发。
需要"只触发一次"，请自行用 `@State` 标志位去重，或者用 SwiftUI 原生的 `.task { }`。

---

## 关于线程安全

- 所有 public API 均 `@MainActor`，回调 closure 也都在主线程执行。
- `dismantleUIViewController` 内部做了主线程兜底（绝大多数场景下 SwiftUI 直接在主线程调用，
  极端场景下会异步派发到主线程），不会因为线程问题崩溃。

---

## License

MIT
