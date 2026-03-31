import Foundation

/// 用户可编辑的路径书签（取代静态 QuickJumpEntry.all）
struct BookmarkEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var path: String        // 完整对象前缀（含文件名前缀部分），可含时间变量

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// 提取目录前缀（strip 最后一个 / 之后的文件名前缀）
    var directoryPrefix: String {
        if path.hasSuffix("/") { return path }
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex...slashIndex])
    }

    /// path 中的时间变量替换为当前日期后的路径
    var resolvedPath: String { path.resolvingDateVariables() }

    // MARK: - Default seeds (from original QuickJumpEntry)

    static let defaults: [BookmarkEntry] = QuickJumpEntry.all.map {
        BookmarkEntry(name: $0.id, path: $0.path)
    }
}

// MARK: - Date variable resolution

extension String {
    /// 将路径中的时间变量替换为当前日期对应的值。
    ///
    /// 支持的变量（大括号包裹）：
    /// - `{YMD}`  → yyyyMMdd，        如 `20260331`
    /// - `{YMD1}` → yyyyMMd1，        如 `20260320`～`20260329` 共享前缀 `2026032`
    ///                                  即 `{YMD1}` 在 31 日时产出 `2026033`
    /// - `{YM}`   → yyyyMM，          如 `202603`
    /// - `{Y}`    → yyyy，            如 `2026`
    /// - `{M}`    → MM，              如 `03`
    /// - `{D}`    → dd，              如 `31`
    /// - `{D1}`   → 日期十位数字，    如 `3`（匹配 30～39，即月底）
    func resolvingDateVariables(date: Date = Date()) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return self }
        let d1 = d / 10   // 十位数字：0→1~9, 1→10~19, 2→20~29, 3→30~39
        // 多字符变量必须先于单字符变量替换，避免 {YM} 被拆成 {Y} + M
        return self
            .replacingOccurrences(of: "{YMD1}", with: String(format: "%04d%02d%d",  y, m, d1))
            .replacingOccurrences(of: "{YMD}",  with: String(format: "%04d%02d%02d", y, m, d))
            .replacingOccurrences(of: "{YM}",   with: String(format: "%04d%02d",    y, m))
            .replacingOccurrences(of: "{Y}",    with: String(format: "%04d",        y))
            .replacingOccurrences(of: "{M}",    with: String(format: "%02d",        m))
            .replacingOccurrences(of: "{D1}",   with: String(format: "%d",          d1))
            .replacingOccurrences(of: "{D}",    with: String(format: "%02d",        d))
    }
}
