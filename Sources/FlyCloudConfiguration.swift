import Foundation

// MARK: - Machine Spec

struct FlyCloudMachineSpec: Codable, Equatable, Sendable {
    let cpuKind: String
    let cpus: Int
    let memoryMB: Int
    let image: String
    let region: String?
    let volumeSizeGB: Int?

    static let `default` = FlyCloudMachineSpec(
        cpuKind: "shared",
        cpus: 1,
        memoryMB: 1024,
        image: "ubuntu:24.04",
        region: nil,
        volumeSizeGB: nil
    )
}

// MARK: - Cloud Configuration

struct FlyCloudConfiguration: Codable, Equatable, Sendable {
    let appName: String
    let machineSpec: FlyCloudMachineSpec
    let volumeName: String?
    let sshUser: String

    /// Populated after machine creation
    var resolvedMachineID: String?
    /// Populated after volume creation
    var resolvedVolumeID: String?

    init(
        appName: String,
        machineSpec: FlyCloudMachineSpec = .default,
        volumeName: String? = nil,
        sshUser: String = "root",
        resolvedMachineID: String? = nil,
        resolvedVolumeID: String? = nil
    ) {
        self.appName = appName
        self.machineSpec = machineSpec
        self.volumeName = volumeName
        self.sshUser = sshUser
        self.resolvedMachineID = resolvedMachineID
        self.resolvedVolumeID = resolvedVolumeID
    }
}

// MARK: - Machine State

enum FlyCloudMachineState: String, Codable, Sendable {
    case creating
    case starting
    case waitingForSSH
    case ready
    case stopping
    case stopped
    case destroying
    case destroyed
    case error
}

// MARK: - SSH Bootstrap

extension FlyCloudConfiguration {
    /// Shell script used as the machine's init command.
    /// Installs sshd, injects the user's public key, and starts sshd in the foreground.
    static func machineInitScript(sshPublicKey: String, sshUser: String) -> String {
        // The script:
        // 1. Installs openssh-server if missing
        // 2. Creates .ssh dir for the target user
        // 3. Writes the authorized key
        // 4. Generates host keys if missing
        // 5. Creates /run/sshd (required by some distros)
        // 6. Execs sshd in the foreground so PID 1 stays alive
        return """
        #!/bin/sh
        set -e
        if ! command -v sshd >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache openssh-server >/dev/null
            elif command -v yum >/dev/null 2>&1; then
                yum install -y -q openssh-server >/dev/null
            fi
        fi
        USER_HOME=$(eval echo ~\(sshUser))
        mkdir -p "$USER_HOME/.ssh"
        echo '\(sshPublicKey)' >> "$USER_HOME/.ssh/authorized_keys"
        chmod 700 "$USER_HOME/.ssh"
        chmod 600 "$USER_HOME/.ssh/authorized_keys"
        if [ "\(sshUser)" != "root" ]; then
            chown -R \(sshUser):\(sshUser) "$USER_HOME/.ssh" 2>/dev/null || true
        fi
        ssh-keygen -A 2>/dev/null || true
        mkdir -p /run/sshd
        exec /usr/sbin/sshd -D -e
        """
    }
}
