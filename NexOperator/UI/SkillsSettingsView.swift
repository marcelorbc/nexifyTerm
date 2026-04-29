import SwiftUI

struct SkillsSettingsView: View {
    @StateObject private var store = SkillStore.shared
    @State private var selectedSkillId: UUID?
    @State private var isEditing = false
    @State private var editingSkill: Skill?
    @State private var showDeleteConfirm = false
    @State private var skillToDelete: Skill?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader
            skillsList
            hintText
        }
    }

    private var sectionHeader: some View {
        HStack {
            Text("Skills")
                .font(.headline)
            Spacer()
            Button {
                editingSkill = Skill(name: "", instruction: "")
                isEditing = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                    Text("Nova Skill")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(NexTheme.accentDim)
                .foregroundColor(.accentColor)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
    }

    private var skillsList: some View {
        Group {
            if store.skills.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(store.skills) { skill in
                        skillRow(skill)
                    }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let skill = editingSkill {
                SkillEditorView(skill: skill, isNew: skill.name.isEmpty) { saved in
                    store.add(saved)
                    isEditing = false
                    editingSkill = nil
                } onCancel: {
                    isEditing = false
                    editingSkill = nil
                }
            }
        }
        .alert("Excluir Skill", isPresented: $showDeleteConfirm) {
            Button("Cancelar", role: .cancel) { skillToDelete = nil }
            Button("Excluir", role: .destructive) {
                if let skill = skillToDelete {
                    store.delete(skill.id)
                    skillToDelete = nil
                }
            }
        } message: {
            if let skill = skillToDelete {
                Text("Tem certeza que deseja excluir a skill \"\(skill.name)\"?")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
            Text("Nenhuma skill criada")
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textSecondary)
            Text("Crie skills para usar como contexto com /nome")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .glassCard(cornerRadius: 8)
    }

    private func skillRow(_ skill: Skill) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skill.icon)
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 28, height: 28)
                .background(NexTheme.accentDim)
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/\(skill.name)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(NexTheme.textPrimary)

                    if !skill.parameters.isEmpty {
                        Text(skill.parameters.map { "{{\($0)}}" }.joined(separator: " "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NexTheme.accent.opacity(0.6))
                    }
                }
                Text(skill.instruction.prefix(80) + (skill.instruction.count > 80 ? "..." : ""))
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 2) {
                Button {
                    editingSkill = skill
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Editar")

                Button {
                    store.duplicate(skill)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Duplicar")

                Button {
                    skillToDelete = skill
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.red.opacity(0.7))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Excluir")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
    }

    private var hintText: some View {
        Text("Use /nome no input para ativar uma skill como contexto. Você também pode pedir ao AI: \"crie uma skill chamada...\"")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

struct SkillEditorView: View {
    @State var skill: Skill
    let isNew: Bool
    let onSave: (Skill) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var instruction: String = ""
    @State private var icon: String = "bolt.fill"

    private let iconOptions = [
        "bolt.fill", "terminal.fill", "server.rack", "cloud.fill",
        "lock.shield.fill", "cpu", "memorychip", "network",
        "globe", "doc.text.fill", "gear", "wrench.fill",
        "hammer.fill", "paintbrush.fill", "chart.bar.fill", "cube.fill",
        "shippingbox.fill", "externaldrive.fill", "antenna.radiowaves.left.and.right", "ladybug.fill"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isNew ? "Nova Skill" : "Editar Skill")
                    .font(.title3.bold())
                Spacer()
                Button("Cancelar") { onCancel() }
                    .keyboardShortcut(.escape)
                Button("Salvar") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || instruction.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.bottom, 4)

            LabeledContent("Nome") {
                HStack(spacing: 4) {
                    Text("/")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(NexTheme.accent)
                    TextField("docker, git, deploy...", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 200)
                }
            }

            LabeledContent("Ícone") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 10), spacing: 4) {
                    ForEach(iconOptions, id: \.self) { iconName in
                        Button {
                            icon = iconName
                        } label: {
                            Image(systemName: iconName)
                                .font(.system(size: 12))
                                .frame(width: 28, height: 28)
                                .background(icon == iconName ? NexTheme.accentDim : NexTheme.surface)
                                .foregroundColor(icon == iconName ? NexTheme.accent : NexTheme.textSecondary)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(icon == iconName ? NexTheme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instrução")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                TextEditor(text: $instruction)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120, maxHeight: 200)
                    .padding(4)
                    .background(NexTheme.surface)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
                Text("Use {{parametro}} para parâmetros dinâmicos. Ex: \"Analise o container {{nome}} na porta {{porta}}\"")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
            }

            if !detectedParams.isEmpty {
                HStack(spacing: 4) {
                    Text("Parâmetros detectados:")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                    ForEach(detectedParams, id: \.self) { param in
                        Text(param)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NexTheme.accentDim)
                            .foregroundColor(NexTheme.accent)
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .onAppear {
            name = skill.name
            instruction = skill.instruction
            icon = skill.icon
        }
    }

    private var detectedParams: [String] {
        Skill.extractParameters(from: instruction)
    }

    private func save() {
        var saved = skill
        saved.name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        saved.instruction = instruction
        saved.icon = icon
        saved.parameters = detectedParams
        saved.updatedAt = Date()
        onSave(saved)
    }
}
