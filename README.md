# SwiftUIPlus

一个轻量的 SwiftUI 能力补全库，目前包含五块：

1. **生命周期**：桥接到 UIKit 真实 `UIViewController` 生命周期，提供
   `viewDidLoad / viewWillAppear / viewDidAppear / viewWillDisappear / viewDidDisappear`
   以及 SwiftUI 原生缺失的「视图真正被销毁」回调。
2. **动画完成**：用 `Animatable` 跟随渲染插值，提供比 `withAnimation(_:completion:)`
   更适合承接业务逻辑的「动画真正画完」回调。
3. **换行策略**：`lineBreakStyle` 把「单行 + 最小缩放」「限行数」「不限行数」三种常用文本策略收成一个修饰符。
4. **整块缩放**：`shrinkToFit` 让图文混排的一整块内容超宽时等比缩小，而不是各段各缩。
5. **即时按下**：`TouchDownButton` / `onTouchDown` 用 UIKit `UIButton` 吃触摸，手指落下立刻回调，
   不走 SwiftUI 在 ScrollView 里「先判断是点还是滚」的那一小段延迟。

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
| `onFirstAppear { }` | 首次 `onAppear` | 用内联 `@State` 去重，只触发一次 |
| `onAnimationCompleted(for:) { }` | `animatableData` 到达终点 | 稳妥的动画完成信号；须挂在 `.animation` **内侧** |
| `stableAnimation(_:value:) { }` | 同上 | `onAnimationCompleted` + `.animation` 的组合便捷 API |
| `lineBreakStyle(_:)` | 布局期 | 单行 / 限行数 / 不限行数三种文本换行策略 |
| `shrinkToFit(maxWidth:maxHeight:)` | 量到需求尺寸后 | 整块内容超宽/超高就等比缩小，只缩不放 |
| `TouchDownButton` / `onTouchDown(...)` | UIKit `.touchDown` 当下 | 按下立刻回调；松开分 inside / outside；滚动抢走触摸走 cancel |

---

## 整块缩放（图文混排超宽时用）

`minimumScaleFactor` 是 `Text` 专属的排版特性：图标 / 形状不认识它，而且**每个 Text 各自**算缩放比。
所以下面这种图文混排一超宽就会翻车——容器把可用宽度分摊给各段，长文案分到的少、缩得很狠，
短数字分到的够用、几乎不缩，同一行里出现两种字号，图标还保持原大小：

```swift
// ❌ 各段各缩，字号不一致
HStack { adIcon; Text(longTitle); coinIcon; Text("2000000") }
    .lineBreakStyle(.oneLine(maxWidth: 200))
```

`shrinkToFit` 改成对整块做渲染变换，字号、图标、子视图间距同比缩小：

```swift
// ✅ 整块等比缩小，比例关系不变
HStack(spacing: 2) { adIcon; Text(longTitle); coinIcon; Text("2000000") }
    .shrinkToFit(maxWidth: 200)
```

实现是三步：`fixedSize()` 按需求尺寸排开 → `onGeometryChange` 量出这个尺寸 → `scaleEffect` 整块缩放，
最后把对外的布局尺寸补成缩放后的尺寸，方便继续参与 `HStack` / `VStack` 排布。
不存在测量回环：`scaleEffect` 不参与布局，`fixedSize` 又忽略父层提议，量到的需求尺寸恒定。

### 注意

1. 内部会加 `fixedSize()`，所以内容里**不要**再依赖父层宽度做自适应（内部的 `Spacer`、
   `frame(maxWidth: .infinity)` 会失去意义）。
2. 首帧还没量到尺寸，按原大小绘制，量到后重绘才带上缩放；不需要缩放的内容两趟结果一致。
3. 文字是被变换缩小的，不是按更小字号重排，缩放比低于约 0.5 时会略微发虚；位图切图只缩不放
   属于降采样，不受影响。

---

## 即时按下（按下立刻缩小、松开立刻复原）

SwiftUI 的 `Button` / `onTapGesture` / `onLongPressGesture` 放进 `ScrollView` 后，系统要先仲裁
「这是点击还是滚动」，按下反馈会慢一拍；用户点得快，缩放动画根本来不及出现。

`TouchDownButton` 底层是透明 `UIButton`，走 `.touchDown` / `.touchUpInside` /
`.touchUpOutside` / `.touchCancel`，手指落下当下就回调。

常见用法是盖在已有卡片上，用按下态做 `scaleEffect`：

```swift
card
    .scaleEffect(isPressed ? 0.96 : 1)
    .onTouchDown {
        isPressed = true
    } onTouchUpInside: {
        isPressed = false
        submit()
    } onTouchUpOutside: {
        isPressed = false
    } onTouchCancel: {
        isPressed = false
    }
```

也可以自己 `overlay { TouchDownButton(...) }`。它没有自身尺寸，必须盖在已有内容上，或先给 `.frame`。

### 注意

1. 热区上的 SwiftUI 手势会被这层 UIButton 吃掉。业务点击请写在 `onTouchUpInside`，不要再叠一层 `onTapGesture`。
2. 按钮进层级后会把**最近外层** `UIScrollView.delaysContentTouches` 设为 `false`，否则 ScrollView 仍会扣住按下。
   滚动本身还能把触摸抢走（走 `onTouchCancel`），只是不再拖延按下。
3. `isExclusiveTouch = true`，同一时刻只有这一块吃触摸，避免两指同时按中两张卡。

---

## 动画完成（推荐用于业务收尾）

系统 `withAnimation { } completion:` 的完成回调挂在**动画事务**上：同拍大重建可能掐断
在飞动画，导致 completion 迟迟不来，把发奖 / 开按钮 / 弹窗队列等业务拖死。

本库的完成信号盯的是 SwiftUI 逐帧推进的 `animatableData`——跟渲染走：

- 动画被掐断、直接跳终点 → 立刻回调（不会挂死）
- 主线程卡顿 → 跟着帧变慢（只会晚，不会早）

### 简单场景（触发值 = 观察值）

```swift
@State private var token: CGFloat = 0

var body: some View {
    content
        .stableAnimation(.easeInOut(duration: 0.25), value: token) {
            // token 这一轮动画真画完了
        }
}

func play() {
    token += 1   // 不要包 withAnimation
}
```

### 弹窗框架常见场景（一条曲线 + 多个进度）

```swift
content
    .onAnimationCompleted(for: appearProgress) { handleAppearFinished() }
    .onAnimationCompleted(for: dismissProgress) { handleDismissFinished() }
    .animation(activeAnimation, value: animationToken)

// 触发出场：
activeAnimation = .easeInOut(duration: 0.25)
animationToken += 1
appearProgress += 1
```

### 硬规则（违反会立刻误报完成）

1. 观察器挂在**常驻**视图上（不要挂在随弹窗内容一起插入/移除的那一层）
2. 观察器必须在 `.animation(_:value:)` 的**内侧**（上游）

> 不要做成全局自由函数去「伪装」`withAnimation { } completion:`——完成信号必须挂在视图树上，
> 自由函数救不了事务被掐断的问题。

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
