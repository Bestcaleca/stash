import SwiftUI

enum GroupEditorTarget: Identifiable {
    case create
    case rename(VaultGroup)
    case delete(VaultGroup)
    case move(ItemSummary)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let group): "rename-\(group.id)"
        case .delete(let group): "delete-\(group.id)"
        case .move(let item): "move-\(item.id)"
        }
    }
}

struct GroupSidebar: View {
    @EnvironmentObject private var model: AppModel
    let present: (GroupEditorTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Eyebrow(text: String(localized: "Groups"))
                    .padding(.leading, 8)
                Spacer()
                IconButton("plus", help: "New Group") { present(.create) }
                    .accessibilityLabel(Text("New Group"))
            }
            ForEach(model.groups) { group in
                HStack(spacing: 2) {
                    SidebarRow(symbol: group.isDefault ? "house" : "folder",
                               title: group.title, count: model.count(inGroup: group.id),
                               selected: model.selectedGroupID == group.id, isDefault: group.isDefault) {
                        model.selectGroup(group.id)
                    }
                    .help(group.title)
                    Menu {
                        Button("Rename Group…") { present(.rename(group)) }
                        if !group.isDefault {
                            Button("Delete Group…", role: .destructive) { present(.delete(group)) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(Color.inkSecondary)
                            .frame(width: 21, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("Manage \(group.title) group"))
                }
            }
        }
    }
}

struct GroupPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: VaultGroup.ID

    var body: some View {
        Picker("Group", selection: $selection) {
            ForEach(model.groups) { group in
                Text(group.title).tag(group.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: GroupEditorTarget
    @State private var name = ""
    @State private var groupID = VaultGroup.personal.id

    private var title: String {
        switch target {
        case .create: String(localized: "New Group")
        case .rename: String(localized: "Rename Group")
        case .delete(let group): String(localized: "Delete “\(group.title)”?")
        case .move: String(localized: "Move to Group")
        }
    }

    private var valid: Bool {
        switch target {
        case .create, .rename: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .delete(let group): !group.isDefault
        case .move(let item): groupID != item.groupID
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.plex(18, weight: .semibold)).foregroundStyle(Color.ink)
            fields
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Color.danger)
                    .font(.plex(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                confirmButton.disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 412)
        .background(Color.canvas)
        .disabled(model.busy)
        .interactiveDismissDisabled(model.busy)
        .onAppear {
            model.error = nil
            switch target {
            case .rename(let group): name = group.title
            case .move(let item): groupID = item.groupID
            default: break
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch target {
        case .create, .rename:
            LabeledInput("Group name") {
                FieldBox(mono: false) {
                    TextField("Group name", text: $name)
                        .labelsHidden()
                }
            }
        case .delete(let group):
            let count = model.count(inGroup: group.id)
            let destination = model.groupTitle(VaultGroup.personal.id)
            Group {
                if count == 0 {
                    Text("This group is empty.")
                } else if count == 1 {
                    Text("One item will move to the default group “\(destination)”.")
                } else {
                    Text("\(count) items will move to the default group “\(destination)”.")
                }
            }
            .font(.plex(13))
            .foregroundStyle(Color.inkSecondary)
        case .move(let item):
            Text(item.name).font(.plex(13)).foregroundStyle(Color.inkSecondary)
            LabeledInput("Group") { GroupPicker(selection: $groupID) }
        }
    }

    @ViewBuilder private var confirmButton: some View {
        switch target {
        case .delete:
            Button("Delete Group", role: .destructive) { submit() }
                .buttonStyle(.borderedProminent)
                .tint(Color.danger)
        case .create:
            Button("Create Group") { submit() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .rename:
            Button("Save") { submit() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .move:
            Button("Move Item") { submit() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func submit() {
        guard valid, !model.busy else { return }
        Task {
            let saved: Bool
            switch target {
            case .create: saved = await model.createGroup(name)
            case .rename(let group): saved = await model.renameGroup(group.id, to: name)
            case .delete(let group): saved = await model.deleteGroup(group.id)
            case .move(let item): saved = await model.moveItem(item.name, to: groupID)
            }
            if saved { dismiss() }
        }
    }
}
