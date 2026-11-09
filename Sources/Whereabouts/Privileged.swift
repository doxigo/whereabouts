import Foundation

/// Root-owned helpers live in one folder, each with a sudoers grant scoped to
/// just that helper, so one admin prompt at setup makes every later call silent.
enum Privileged {
    static let appDir = "/Library/Application Support/Whereabouts"

    static func q(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// sudoers escapes literal spaces in command paths with a backslash.
    static func sudoersPath(_ path: String) -> String { path.replacingOccurrences(of: " ", with: "\\ ") }

    /// The account name, if it's safe to write into a sudoers rule.
    static func sudoUser() -> String? {
        let user = NSUserName()
        return user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) ? user : nil
    }

    /// Installs `helper` at `helperPath` (root:wheel 755) and `grants` at
    /// `sudoersPath`, refusing anything visudo rejects.
    static func installScript(helperPath: String, helper: String, sudoersPath: String, grants: [String]) -> String {
        """
        #!/bin/bash
        set -uo pipefail
        SUDOERS_TMP="$(/usr/bin/mktemp)"
        /bin/mkdir -p \(q(appDir)) || exit 1
        /usr/sbin/chown root:wheel \(q(appDir))
        /bin/chmod 755 \(q(appDir))
        cat > \(q(helperPath)) <<'WA_HELPER_EOF'
        \(helper)
        WA_HELPER_EOF
        /usr/sbin/chown root:wheel \(q(helperPath))
        /bin/chmod 755 \(q(helperPath))
        cat > "$SUDOERS_TMP" <<'WA_SUDOERS_EOF'
        \(grants.joined(separator: "\n"))
        WA_SUDOERS_EOF
        if ! /usr/sbin/visudo -cf "$SUDOERS_TMP"; then
          /bin/rm -f "$SUDOERS_TMP"
          echo "Whereabouts: invalid sudoers syntax, aborting" >&2
          exit 1
        fi
        /usr/sbin/chown root:wheel "$SUDOERS_TMP"
        /bin/chmod 440 "$SUDOERS_TMP"
        /bin/mv "$SUDOERS_TMP" \(q(sudoersPath))
        """
    }

    /// The AppleScript that runs `script` as root. The script travels inline: a file in the user's
    /// temp folder could be rewritten by any program running as the user while the password dialog waits.
    static func appleScript(_ script: String, prompt: String) -> String {
        func osa(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "do shell script \(osa("/bin/bash -c " + q(script))) with prompt \(osa(prompt)) with administrator privileges"
    }

    /// Runs a script once under a single admin-password prompt.
    @discardableResult static func run(_ script: String, prompt: String) async throws -> String {
        try await Whereabouts.run("/usr/bin/osascript", ["-e", appleScript(script, prompt: prompt)], timeout: 60)
    }

    static func isUserCanceled(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("-128") || text.lowercased().contains("user canceled")
    }
}
