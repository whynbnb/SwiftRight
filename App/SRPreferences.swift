import AppKit
import Combine
import SwiftUI

// MARK: - 语言

enum SRLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// 这三个名字刻意不走本地化：语言选择器上，每个选项都该用它自己的语言写，
    /// 否则界面是英文时用户看到的是"简体中文"的英文翻译，反而找不到要选哪个。
    var displayName: String {
        switch self {
        case .system: return SRPreferences.shared.localized("跟随系统")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

// MARK: - 主题

enum SRThemePreference: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .system: return SRPreferences.shared.localized("跟随系统")
        case .light: return SRPreferences.shared.localized("浅色")
        case .dark: return SRPreferences.shared.localized("深色")
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - 偏好

/// App 自身的偏好。与 commands.json 分开存：
/// 这些设置访达扩展一概用不到，没必要塞进那份共享配置里。
final class SRPreferences: ObservableObject {

    static let shared = SRPreferences()

    @Published var language: SRLanguage {
        didSet {
            guard oldValue != language else { return }
            defaults.set(language.rawValue, forKey: Keys.language)
            resolveBundle()
            languageDidChange.send()
        }
    }

    @Published var theme: SRThemePreference {
        didSet {
            guard oldValue != theme else { return }
            defaults.set(theme.rawValue, forKey: Keys.theme)
            applyTheme()
        }
    }

    /// 后台命令失败时自动弹出输出窗口。
    @Published var openOutputOnFailure: Bool {
        didSet { defaults.set(openOutputOnFailure, forKey: Keys.openOutputOnFailure) }
    }

    /// AppKit 那几处菜单是命令式搭出来的，语言变了得重建，靠这个通知。
    let languageDidChange = PassthroughSubject<Void, Never>()

    private let defaults = UserDefaults.standard
    private var localizedBundle: Bundle?

    private enum Keys {
        static let language = "preferredLanguage"
        static let theme = "preferredTheme"
        static let openOutputOnFailure = "openOutputOnFailure"
    }

    private init() {
        language = SRLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        theme = SRThemePreference(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        openOutputOnFailure = defaults.object(forKey: Keys.openOutputOnFailure) as? Bool ?? true
        resolveBundle()
    }

    // MARK: - 生效语言

    /// `.system` 解析成实际使用的语言。
    var effectiveLanguage: SRLanguage {
        guard language == .system else { return language }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .chinese : .english
    }

    // MARK: - 取词

    /// 源语言是中文，所以直接拿中文原文当 key。
    /// 中文时返回 key 本身，英文时查 en.lproj/Localizable.strings。
    /// 查不到就回退成中文原文 —— 界面会中英混排，但至少不会显示成裸 key。
    func localized(_ key: String) -> String {
        guard effectiveLanguage == .english, let bundle = localizedBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private func resolveBundle() {
        guard effectiveLanguage == .english,
              let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            localizedBundle = nil
            return
        }
        localizedBundle = bundle
    }

    // MARK: - 主题

    func applyTheme() {
        NSApp.appearance = theme.appearance
    }
}

/// 取词的简写。
///
/// 之所以能用全局函数而不必让每个视图都观察 SRPreferences：
/// SRWindowManager 把所有窗口的根视图套在 SRLocalizedRoot 里，
/// 语言一变整棵树会被 `.id()` 强制重建，`L()` 自然重新求值。
func L(_ key: String) -> String {
    SRPreferences.shared.localized(key)
}

/// 带插值的取词：`L("已选中 %@ 项", "3")`。
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: SRPreferences.shared.localized(key), arguments: arguments)
}

// MARK: - 根容器

/// 所有窗口的根。负责注入环境对象，并在语言切换时重建整棵视图树。
struct SRLocalizedRoot<Content: View>: View {

    @ObservedObject private var preferences = SRPreferences.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environmentObject(preferences)
            // 用生效语言而不是 language 本身：选了"跟随系统"时，
            // 系统语言变化也要能触发重建。
            .id(preferences.effectiveLanguage)
    }
}
