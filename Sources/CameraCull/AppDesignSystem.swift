import SwiftUI

enum AppButtonRole {
    case primary
    case secondary
    case quiet
    case destructive
}

enum AppControlMetrics {
    static let compactIconSide: CGFloat = 28
    static let regularIconSide: CGFloat = 32
    static let selectionSide: CGFloat = 28
    static let overlayHorizontalPadding: CGFloat = 9
    static let overlayVerticalPadding: CGFloat = 5
}

private struct AppButtonModifier: ViewModifier {
    let role: AppButtonRole
    let controlSize: ControlSize

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content
                .buttonStyle(.borderedProminent)
                .controlSize(controlSize)
        case .secondary:
            content
                .buttonStyle(.bordered)
                .controlSize(controlSize)
        case .quiet:
            content
                .buttonStyle(.borderless)
                .controlSize(controlSize)
        case .destructive:
            content
                .buttonStyle(.bordered)
                .controlSize(controlSize)
                .tint(.red)
        }
    }
}

extension View {
    func appButton(_ role: AppButtonRole, controlSize: ControlSize = .regular) -> some View {
        modifier(AppButtonModifier(role: role, controlSize: controlSize))
    }

    func appIconButton(compact: Bool = false) -> some View {
        appButton(.quiet)
            .frame(
                width: compact ? AppControlMetrics.compactIconSide : AppControlMetrics.regularIconSide,
                height: compact ? AppControlMetrics.compactIconSide : AppControlMetrics.regularIconSide
            )
            .contentShape(Rectangle())
    }
}

struct AppSelectionButtonStyle: ButtonStyle {
    let isSelected: Bool
    var accent: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: AppControlMetrics.selectionSide, height: AppControlMetrics.selectionSide)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                isSelected
                    ? accent.opacity(0.18)
                    : configuration.isPressed ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.55) : .clear)
            }
    }
}

struct PreviewOverlayCapsuleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, AppControlMetrics.overlayHorizontalPadding)
            .padding(.vertical, AppControlMetrics.overlayVerticalPadding)
            .background(.black.opacity(configuration.isPressed ? 0.82 : 0.68), in: Capsule())
            .contentShape(Capsule())
    }
}

struct PreviewMetadataCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, AppControlMetrics.overlayHorizontalPadding)
            .padding(.vertical, AppControlMetrics.overlayVerticalPadding)
            .background(.black.opacity(0.68), in: Capsule())
    }
}
