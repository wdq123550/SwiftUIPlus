// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftUI

//MARK: - View Identity/Life cycle
public extension View {
    
    /// 当视图真正挂载到渲染树（Identity 确立）时触发
    /// 解决 Struct 多次实例化导致的 init 重复执行问题
    func onIdentityAppear(perform: @escaping @Sendable () -> Void) -> some View {
        self.task {
            perform()
        }
    }

    /// 当视图真正从渲染树拔除（Identity 销毁）时触发
    /// 解决 deinit 在临时实例中提前触发的问题
    func onIdentityDisappear(perform: @escaping @Sendable () -> Void) -> some View {
        self.task {
            // 利用 Task 的取消机制
            defer { perform() }
            
            // 维持挂起状态，直到收到 Identity 销毁的取消信号
            try? await Task.sleep(nanoseconds: UInt64.max)
        }
    }
}
