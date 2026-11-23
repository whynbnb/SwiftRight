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

// MARK: - 常驻方式

/// App 在后台以什么形态存在。
///
/// 这三种是同一个权衡的三个点：扩展被强制沙盒、起不了外部进程，
/// 所以必须有个非沙盒进程来执行命令。"不常驻"就等于"每次冷启动"，
/// 没有第三条路。实测冷热差距约 0.11 秒。
enum SRResidencyMode: String, CaseIterable, Identifiable, Codable {
    /// 常驻，菜单栏有图标。
    case menuBar
    /// 常驻，但不显示图标 —— 靠双击 App 打开界面。
    case hidden
    /// 命令跑完就退出，不常驻。
    case autoQuit

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .menuBar: return SRPreferences.shared.localized("常驻菜单栏")
        case .hidden: return SRPreferences.shared.localized("常驻但隐藏图标")
        case .autoQuit: return SRPreferences.shared.localized("用完自动退出")
        }
    }

    var localizedDetail: String {
        switch self {
        case .menuBar:
            return SRPreferences.shared.localized("菜单栏有图标，点它就能打开管理和设置。命令响应最快。")
        case .hidden:
            return SRPreferences.shared.localized("进程仍常驻，响应一样快，但菜单栏看不到图标 —— 要打开界面得双击「应用程序」里的 SwiftRight。")
        case .autoQuit:
            return SRPreferences.shared.localized("命令跑完、窗口关掉之后就退出，平时不占任何位置。代价是每次都要冷启动，约慢 0.1 秒。")
        }
    }
}

// MARK: - 偏好

/// App 自身的偏好。与 commands.json 分开存：
/// 这些设置访达扩展一概用不到，没必要塞进那份共享配置里。
final class SRPreferences: ObservableObject {

    // 语言/主题这些偏好只在主线程改；取词（localized）会在后台读，
    // 但读到的只是不可变快照，这里显式说明共享是安全的。
    nonisolated(unsafe) static let shared = SRPreferences()

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

    /// 「在终端中运行」结束后，是否接一个交互式 shell 把窗口留住。
    @Published var keepTerminalOpen: Bool {
        didSet { defaults.set(keepTerminalOpen, forKey: Keys.keepTerminalOpen) }
    }

    /// 后台常驻形态。
    @Published var residency: SRResidencyMode {
        didSet {
            guard oldValue != residency else { return }
            defaults.set(residency.rawValue, forKey: Keys.residency)
            residencyDidChange.send()
        }
    }

    /// AppKit 那几处菜单是命令式搭出来的，语言变了得重建，靠这个通知。
    let languageDidChange = PassthroughSubject<Void, Never>()
    /// 常驻方式改了要装/卸菜单栏图标，也靠通知，避免 SRPreferences 反向依赖 AppDelegate。
    let residencyDidChange = PassthroughSubject<Void, Never>()

    private let defaults = UserDefaults.standard

    /// 取词用的只读快照。`localized(_:)` 可能在后台线程被调用（比如命令输出
    /// 的状态文案），所以这里用锁保护，而不是直接读 @Published 的 language。
    private struct Localizer: @unchecked Sendable {
        let isEnglish: Bool
        let bundle: Bundle?
    }
    private let localizerLock = NSLock()
    private var localizer = Localizer(isEnglish: false, bundle: nil)

    private enum Keys {
        static let language = "preferredLanguage"
        static let theme = "preferredTheme"
        static let openOutputOnFailure = "openOutputOnFailure"
        static let keepTerminalOpen = "keepTerminalOpen"
        static let residency = "residencyMode"
    }

    private init() {
        language = SRLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        theme = SRThemePreference(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        openOutputOnFailure = defaults.object(forKey: Keys.openOutputOnFailure) as? Bool ?? true
        keepTerminalOpen = defaults.object(forKey: Keys.keepTerminalOpen) as? Bool ?? true
        residency = SRResidencyMode(rawValue: defaults.string(forKey: Keys.residency) ?? "")
            ?? .menuBar
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
        localizerLock.lock()
        let snapshot = localizer
        localizerLock.unlock()
        guard snapshot.isEnglish, let bundle = snapshot.bundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private func resolveBundle() {
        let isEnglish = effectiveLanguage == .english
        let bundle: Bundle? = {
            guard isEnglish,
                  let path = Bundle.main.path(forResource: "en", ofType: "lproj")
            else { return nil }
            return Bundle(path: path)
        }()
        localizerLock.lock()
        localizer = Localizer(isEnglish: isEnglish, bundle: bundle)
        localizerLock.unlock()
    }

    // MARK: - 主题

    /// AppKit 的外观只能在主线程改。`theme` 是值类型，先快照再切换隔离域，
    /// 避免把 self 或 NSAppearance 这些非 Sendable 对象带过去。
    func applyTheme() {
        let theme = self.theme
        if Thread.isMainThread {
            MainActor.assumeIsolated { NSApp.appearance = theme.appearance }
        } else {
            Task { @MainActor in NSApp.appearance = theme.appearance }
        }
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
