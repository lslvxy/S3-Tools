import Foundation

/// 解析 awscli 风格的 INI 配置文件（~/.aws/credentials, ~/.aws/config）
final class INIParser {

    struct Section {
        var name: String
        var values: [String: String]

        subscript(key: String) -> String? {
            values[key]
        }
    }

    static func parse(url: URL) throws -> [String: Section] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(string: content)
    }

    static func parse(string: String) -> [String: Section] {
        var sections: [String: Section] = [:]
        var currentSection: Section? = nil

        let lines = string.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 忽略空行和注释
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            // Section 头 [profile name] 或 [name]
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let prev = currentSection {
                    sections[prev.name] = prev
                }
                var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                // ~/.aws/config 中 profile 写成 [profile offline]
                if name.hasPrefix("profile ") {
                    name = String(name.dropFirst("profile ".count))
                }
                currentSection = Section(name: name, values: [:])
                continue
            }

            // key = value
            if let eqIdx = line.firstIndex(of: "=") {
                let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
                currentSection?.values[key] = value
            }
        }

        if let last = currentSection {
            sections[last.name] = last
        }

        return sections
    }
}
