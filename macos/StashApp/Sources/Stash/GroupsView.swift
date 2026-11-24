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
    @State private var showingGroups = false
    @FocusState private var focusedGroup: VaultGroup.ID?

    var body: some View {
        let title = model.groupTitle(selection)
        Button { showingGroups.toggle() } label: {
            HStack(spacing: 8) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary)
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(Text("Group"))
        .accessibilityValue(Text(title))
        .help(title)
        .popover(isPresented: $showingGroups, arrowEdge: .bottom) {
            ViewThatFits(in: .vertical) {
                options.fixedSize(horizontal: false, vertical: true)
                ScrollView { options }
            }
            .frame(width: 192)
            .frame(maxHeight: 224)
            .padding(6)
            .onAppear { focusedGroup = selection }
            .onKeyPress(.downArrow) { moveFocus(by: 1) }
            .onKeyPress(.upArrow) { moveFocus(by: -1) }
        }
    }

    private var options: some View {
        VStack(spacing: 2) {
            ForEach(model.groups) { group in
                Button {
                    selection = group.id
                    showingGroups = false
                } label: {
                    HStack(spacing: 8) {
                        Text(group.title)
                            .font(.plex(13))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.amberText)
                            .opacity(group.id == selection ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(group.id == (focusedGroup ?? selection) ? Color.amberTint : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($focusedGroup, equals: group.id)
                .accessibilityAddTraits(group.id == selection ? .isSelected : [])
            }
        }
    }

    private func moveFocus(by step: Int) -> KeyPress.Result {
        guard let index = model.groups.firstIndex(where: { $0.id == (focusedGroup ?? selection) }) else {
            return .ignored
        }
        let next = index + step
        if model.groups.indices.contains(next) { focusedGroup = model.groups[next].id }
        return .handled
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
