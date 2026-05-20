import Foundation

// NSException 在 Swift 里无法用 try/catch 捕获
// 需要一个 ObjC 桥接来安全读取 KVC 键
// 用 NSObject 的 responds(toSelector:) 做前置检查即可，
// 但 KVC key 检查最安全的方式是在 ObjC 侧用 @try/@catch

// 纯 Swift 可用的安全方案：
// 利用 responds(toSelector:) 检查对应的 getter selector 是否存在

extension NSObject {
    /// 安全读取 KVC 值，键不存在时返回 nil 而不是崩溃
    func safeValue(forKey key: String) -> Any? {
        // 检查对应的 selector 是否存在（getter 名即 key 本身）
        let sel = NSSelectorFromString(key)
        guard responds(to: sel) else { return nil }
        return value(forKey: key)
    }
}
