import Foundation

/// 对可能含有 EasyConnect CLI（`-p` 密码等）的字符串做脱敏，避免写入应用内日志或系统日志。
enum LogRedaction {
    /// 将 `-p` / `-p "..."` 形式的密码参数替换为占位符。
    static func redactEasyConnectCLI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"-p\s+(\S+|\"[^\"]*\")"#,
            options: []
        ) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "-p ***")
    }
}
