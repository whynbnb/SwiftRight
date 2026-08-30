import Combine
import Foundation

/// 文件模板库。存 UserDefaults —— 访达扩展用不到它，
/// 它只在"生成右键命令"这一刻起作用，生成出来的是普通命令。
final class SRTemplateStore: ObservableObject {

    static let shared = SRTemplateStore()

    @Published private(set) var templates: [SRFileTemplate] = []

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let templates = "fileTemplates"
        static let seeded = "fileTemplatesSeeded"
    }

    private init() {
        templates = loadStored()
        // 只在头一次装填内置模板。用户把它们全删了之后不该又冒出来。
        if templates.isEmpty && !defaults.bool(forKey: Keys.seeded) {
            templates = SRFileTemplate.builtins()
            defaults.set(true, forKey: Keys.seeded)
            persist()
        }
    }

    // MARK: - 增删改

    @discardableResult
    func add() -> SRFileTemplate {
        var template = SRFileTemplate()
        template.name = L("新模板")
        template.defaultName = L("未命名")
        template.fileExtension = "txt"
        template.sortIndex = templates.count
        templates.append(template)
        persist()
        return template
    }

    func update(_ template: SRFileTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        persist()
        // 模板改了，已经生成到菜单里的那条命令要跟着变，
        // 否则界面上看到的和右键实际产出的会对不上。
        SRAppModel.shared.syncTemplateCommand(template)
    }

    func remove(_ id: UUID) {
        templates.removeAll { $0.id == id }
        normalize()
        persist()
    }

    func restoreBuiltins() -> Int {
        var added = 0
        for var builtin in SRFileTemplate.builtins() {
            // 按名字 + 扩展名判重，避免重复塞入同一套。
            let name: String = builtin.name
            let ext: String = builtin.fileExtension
            var exists = false
            for existing in templates where existing.name == name && existing.fileExtension == ext {
                exists = true
                break
            }
            guard !exists else { continue }
            builtin.id = UUID()
            builtin.sortIndex = templates.count
            templates.append(builtin)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    func move(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
        normalize()
        persist()
    }

    private func normalize() {
        for index in templates.indices where templates[index].sortIndex != index {
            templates[index].sortIndex = index
        }
    }

    // MARK: - 存取

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: Keys.templates)
    }

    private func loadStored() -> [SRFileTemplate] {
        guard let data = defaults.data(forKey: Keys.templates),
              let decoded = try? JSONDecoder().decode([SRFileTemplate].self, from: data)
        else { return [] }
        return decoded.sorted { $0.sortIndex < $1.sortIndex }
    }
}
