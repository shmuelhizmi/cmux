import SwiftUI

/// Full-screen centered progress overlay shown while a cloud workspace is provisioning.
/// Displays a step-by-step checklist with checkmarks, spinners, and pending circles.
struct CloudProvisioningOverlay: View {
    @ObservedObject var workspace: Workspace

    private var steps: [ProvisioningStep] {
        Self.steps(
            for: workspace.cloudMachineState,
            errorAtStep: workspace.cloudMachineErrorAtStep,
            errorDetail: workspace.cloudMachineDetail,
            stepOutput: workspace.cloudMachineStepOutput
        )
    }

    private var title: String {
        String(localized: "cloud.provisioning.title", defaultValue: "Setting up workspace")
    }

    private var subtitle: String {
        workspace.cloudConfiguration?.workspaceLabel ?? ""
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Git branch icon in circle
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.25))
                        .frame(width: 80, height: 80)
                    Circle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, 4)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 28)

                // Steps
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        StepRow(step: step)
                    }
                }
                .frame(width: 340)
                .padding(.bottom, 24)

                if workspace.cloudMachineState == .error {
                    // Error actions
                    HStack(spacing: 12) {
                        Button(String(localized: "cloud.provisioning.retry", defaultValue: "Retry")) {
                            workspace.sandboxController?.start()
                        }
                        .buttonStyle(.bordered)

                        Button(String(localized: "cloud.provisioning.continue", defaultValue: "Continue Anyway")) {
                            workspace.cloudMachineStepOutput = nil
                            workspace.cloudMachineState = .ready
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 4)
                } else {
                    Text(String(localized: "cloud.provisioning.footer", defaultValue: "Takes 10s to a few minutes depending on the size of your repo"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
        }
        .accessibilityIdentifier("CloudProvisioningOverlay")
    }

    // MARK: - Step Definitions

    static func steps(
        for state: DaytonaCloudMachineState,
        errorAtStep: DaytonaCloudMachineState? = nil,
        errorDetail: String? = nil,
        stepOutput: String? = nil
    ) -> [ProvisioningStep] {
        let allSteps: [(label: String, triggerState: DaytonaCloudMachineState)] = [
            (String(localized: "cloud.step.creating", defaultValue: "Creating sandbox..."), .creating),
            (String(localized: "cloud.step.starting", defaultValue: "Starting sandbox..."), .starting),
            (String(localized: "cloud.step.ssh", defaultValue: "Obtaining SSH access..."), .waitingForSSH),
            (String(localized: "cloud.step.connecting", defaultValue: "Connecting to sandbox..."), .connecting),
            (String(localized: "cloud.step.cloning", defaultValue: "Cloning repository..."), .cloningRepository),
            (String(localized: "cloud.step.ready", defaultValue: "Ready"), .ready),
        ]

        let stateOrder: [DaytonaCloudMachineState] = [
            .creating, .starting, .waitingForSSH, .connecting, .cloningRepository, .ready,
        ]

        // For error state, use the step where the error occurred
        let errorStepIndex = errorAtStep.flatMap { stateOrder.firstIndex(of: $0) }
        let currentIndex: Int
        if state == .error {
            currentIndex = errorStepIndex ?? (stateOrder.count - 1)
        } else {
            currentIndex = stateOrder.firstIndex(of: state) ?? -1
        }

        return allSteps.enumerated().map { index, step in
            let stepIndex = stateOrder.firstIndex(of: step.triggerState) ?? index
            let status: ProvisioningStep.Status
            var detail: String?
            if state == .error && stepIndex == currentIndex {
                status = .error
                detail = errorDetail
            } else if stepIndex < currentIndex {
                status = .completed
            } else if stepIndex == currentIndex && state != .error {
                status = .active
                detail = stepOutput
            } else {
                status = .pending
            }
            return ProvisioningStep(label: step.label, status: status, detail: detail)
        }
    }
}

// MARK: - Models

struct ProvisioningStep {
    enum Status {
        case pending
        case active
        case completed
        case error
    }

    let label: String
    let status: Status
    var detail: String?
}

// MARK: - Step Row

private struct StepRow: View {
    let step: ProvisioningStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.label)
                    .font(.system(size: 13))
                    .foregroundStyle(textColor)
                if let detail = step.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(step.status == .error ? .red.opacity(0.7) : .secondary)
                        .textSelection(.enabled)
                        .lineLimit(step.status == .error ? 8 : 3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundView)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
        case .active:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.red)
        case .pending:
            Circle()
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1.5)
                .frame(width: 14, height: 14)
        }
    }

    private var textColor: Color {
        switch step.status {
        case .completed: return .secondary
        case .active: return .primary
        case .error: return .red.opacity(0.9)
        case .pending: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch step.status {
        case .active:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                )
        case .completed:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.15), lineWidth: 1)
                )
        default:
            Color.clear
        }
    }
}
