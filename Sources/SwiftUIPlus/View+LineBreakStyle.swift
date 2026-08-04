//
//  View+LineBreakStyle.swift
//  SwiftUIPlus
//

import SwiftUI

// MARK: - 1. 样式配置环境
public struct LineBreakStyleConfiguration {
    let content: AnyView
    init(_ content: some View) {
        self.content = AnyView(content)
    }
}

// MARK: - 2. 样式协议
public protocol LineBreakStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: LineBreakStyleConfiguration) -> Body
}

// MARK: - 3. 具体样式实现
struct InfinityLineBreakStyle: LineBreakStyle {
    var alignment: TextAlignment
    var maxWidth: CGFloat
    func makeBody(configuration: LineBreakStyleConfiguration) -> some View {
        configuration.content
            .multilineTextAlignment(alignment)                              // 设置多行文本的水平对齐方式
            .lineLimit(nil)                                                 // 不限制行数，让文本能换任意多行
            .fixedSize(horizontal: false, vertical: true)                   // 让文本水平方向接受父约束、垂直方向按内容撑开高度（避免被压行截断）
            .frame(maxWidth: maxWidth, alignment: alignment.toFrameAlignment()) // 限制文本的最大宽度，超出即换行
    }
}

struct LimitLineBreakStyle: LineBreakStyle {
    let lineLimit: Int
    var alignment: TextAlignment
    var maxWidth: CGFloat
    var minimumScaleFactor: CGFloat
    func makeBody(configuration: LineBreakStyleConfiguration) -> some View {
        configuration.content
            .multilineTextAlignment(alignment)                              // 设置多行文本的水平对齐方式
            .lineLimit(lineLimit)                                           // 限制文本的最大行数
            .minimumScaleFactor(minimumScaleFactor)                         // 当文本在限定行数内放不下时，允许缩小字号而非截断
            .frame(maxWidth: maxWidth, alignment: alignment.toFrameAlignment()) // 限制文本的最大宽度，作为触发换行与缩放的约束来源
            .fixedSize(horizontal: false, vertical: true)                   // 让高度按（缩放后）内容撑开，水平方向仍受最大宽度约束
            .scaledToFill()                                                 // 修正 ScrollView 下 minimumScaleFactor 提前按最小比例缩放的问题：让文本在不定提议下拿到确定尺寸
    }
}

struct OneLineBreakStyle: LineBreakStyle {
    var maxWidth: CGFloat
    var minimumScaleFactor: CGFloat
    var alignment: TextAlignment
    func makeBody(configuration: LineBreakStyleConfiguration) -> some View {
        configuration.content
            .lineLimit(1)                                                   // 强制单行显示，不换行
            .minimumScaleFactor(minimumScaleFactor)                         // 单行放不下时缩小字号而非截断，避免撑开而顶位移兄弟视图
            .frame(maxWidth: maxWidth, alignment: alignment.toFrameAlignment()) // 限制最大宽度，作为触发单行缩放的约束来源
            .multilineTextAlignment(alignment)                              // 设置文本对齐方式
            .scaledToFill()                                                 // 修正 ScrollView 下 minimumScaleFactor 提前按最小比例缩放的问题：让文本在不定提议下拿到确定尺寸
    }
}

// MARK: - 4. 解决提示问题的关键：类型包装器 (The "SwiftUI Way")
/// 就像 SwiftUI 的 `ButtonStyle` 对应 `AnyButtonStyle` 一样
/// 我们创建一个具体的包装类，这样 View 扩展就不再需要泛型，提示就会变得极速。
public struct LineBreak {
    private let _makeBody: (LineBreakStyleConfiguration) -> AnyView

    init<S: LineBreakStyle>(_ style: S) {
        self._makeBody = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: LineBreakStyleConfiguration) -> some View {
        _makeBody(configuration)
    }
}

// MARK: - 5. 定义静态工厂方法
/// 现在我们将静态方法放在具体的 LineBreak 上，而不是协议扩展里
public extension LineBreak {
    static func oneLine(maxWidth: CGFloat, alignment: TextAlignment = .center, minScale: CGFloat = 0.1) -> LineBreak {
        LineBreak(OneLineBreakStyle(maxWidth: maxWidth, minimumScaleFactor: minScale, alignment: alignment))
    }

    static func limit(maxWidth: CGFloat, line: Int, alignment: TextAlignment = .center, minScale: CGFloat = 0.1) -> LineBreak {
        LineBreak(LimitLineBreakStyle(lineLimit: line, alignment: alignment, maxWidth: maxWidth, minimumScaleFactor: minScale))
    }

    static func infinity(maxWidth: CGFloat, alignment: TextAlignment = .center) -> LineBreak {
        LineBreak(InfinityLineBreakStyle(alignment: alignment, maxWidth: maxWidth))
    }
}

// MARK: - 6. View 扩展 (不再使用泛型 S)
public extension View {
    /// 关键：这里直接接受 LineBreak 具体的结构体，Xcode 提示会非常稳定
    func lineBreakStyle(_ style: LineBreak) -> some View {
        style.makeBody(configuration: LineBreakStyleConfiguration(self))
    }
}

// MARK: - 7. 辅助
extension TextAlignment {
    func toFrameAlignment() -> Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
