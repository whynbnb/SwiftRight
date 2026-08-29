import Foundation

/// 模型枚举的界面文案。
///
/// 单独放在 App target：这些字符串要过 `L()` 本地化，
/// 而 `L()` 依赖 SRPreferences，只存在于主 App。
/// Shared/ 里的模型必须能被沙盒扩展独立编译，不能有这层依赖。

extension SRRunMode {
    var displayName: String {
        switch self {
        case .background: return L("后台静默运行")
        case .captureOutput: return L("显示输出窗口")
        case .terminal: return L("在终端中运行")
        }
    }
}

extension SRWorkingDirectory {
    var displayName: String {
        switch self {
        case .selectionParent: return L("选中项所在文件夹")
        case .selectionItself: return L("选中的文件夹本身")
        case .targetFolder: return L("当前访达窗口")
        case .custom: return L("自定义路径")
        }
    }
}

extension SRSelectionKind {
    var displayName: String {
        switch self {
        case .any: return L("文件和文件夹")
        case .filesOnly: return L("仅文件")
        case .foldersOnly: return L("仅文件夹")
        }
    }
}
