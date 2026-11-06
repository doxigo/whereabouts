import Foundation

func runtimeReportFailed(_ report: String) -> Bool {
    report.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("FAIL:") }
}

@MainActor func liveFirewallTest() async {
    let anchor = "com.apple/099.WATest-" + UUID().uuidString
    let helper = KillSwitch.helperScript
        .replacingOccurrences(of: "ANCHOR=" + Privileged.q(KillSwitch.anchor), with: "ANCHOR=" + Privileged.q(anchor))
        .replacingOccurrences(of: "TOKEN_FILE=" + Privileged.q(KillSwitch.tokenFile), with: "TOKEN_FILE=\"$TEST_ROOT/token\"")
    let script = #"""
    #!/bin/bash
    set -uo pipefail
    export TEST_ROOT=$(/usr/bin/mktemp -d /private/tmp/whereabouts-firewall.XXXXXX)
    [ -n "$TEST_ROOT" ] && [ -d "$TEST_ROOT" ] || exit 1
    /bin/chmod 700 "$TEST_ROOT"
    cat > "$TEST_ROOT/helper" <<'WA_TEST_HELPER'
    \#(helper)
    WA_TEST_HELPER
    /bin/chmod 700 "$TEST_ROOT/helper"
    cleanup() {
      "$TEST_ROOT/helper" release >/dev/null 2>&1
    }
    trap cleanup EXIT HUP INT TERM
    WATCHDOG=com.doxigo.Whereabouts.RuntimeTest.\#(UUID().uuidString)
    cat > "$TEST_ROOT/watchdog" <<'WA_WATCHDOG'
    #!/bin/bash
    export TEST_ROOT="$1"
    /bin/sleep 40
    "$TEST_ROOT/helper" release >/dev/null 2>&1
    /bin/rm -rf "$TEST_ROOT"
    /bin/launchctl remove "$2"
    WA_WATCHDOG
    /bin/chmod 700 "$TEST_ROOT/watchdog"
    if ! /bin/launchctl submit -l "$WATCHDOG" -- /bin/bash "$TEST_ROOT/watchdog" "$TEST_ROOT" "$WATCHDOG"; then
      echo 'FAIL: independent watchdog could not start'; /bin/rm -rf "$TEST_ROOT"; exit 0
    fi
    echo "Watchdog directory: $TEST_ROOT"
    if [ \#(CommandLine.arguments.contains("--watchdog-only") ? "1" : "0") = 1 ]; then
      echo 'Watchdog-only test: no firewall rules loaded.'; exit 0
    fi
    https() { /usr/bin/curl --noproxy '*' -4 -fsS --connect-timeout 2 --max-time 3 "$@" -o /dev/null; }
    dns() { /usr/bin/dig @1.1.1.1 example.com A +time=1 +tries=1 +short 2>/dev/null | /usr/bin/grep -qE '^[0-9]+\.'; }
    IP=$(/usr/bin/dig api.ipify.org A +short +time=2 +tries=1 | /usr/bin/grep -E '^[0-9]+\.' | /usr/bin/head -1)
    OTHER=$(/usr/bin/dig example.com A +short +time=2 +tries=1 | /usr/bin/grep -E '^[0-9]+\.' | /usr/bin/head -1)
    if [ -z "$IP" ] || ! https --resolve "api.ipify.org:443:$IP" https://api.ipify.org; then
      echo 'SKIP: baseline HTTPS unavailable; firewall was not engaged.'; exit 0
    fi
    BASE_DNS=0; dns && BASE_DNS=1
    BASE_OTHER=0
    if [ -n "$OTHER" ] && https --resolve "example.com:443:$OTHER" https://example.com; then BASE_OTHER=1; fi
    echo 'PASS: baseline HTTPS reachable'
    if ! RESULT=$("$TEST_ROOT/helper" engage 2>&1); then
      printf 'FAIL: engage: %s\n' "$RESULT"
      /sbin/pfctl -s info 2>&1
      /sbin/pfctl -s rules 2>&1
      exit 0
    fi
    if https --resolve "api.ipify.org:443:$IP" https://api.ipify.org 2>/dev/null; then echo 'FAIL: full block allowed HTTPS'; else echo 'PASS: full block stopped HTTPS'; fi
    if [ "$BASE_DNS" = 1 ]; then
      if dns; then echo 'FAIL: full block allowed public UDP DNS'; else echo 'PASS: full block stopped public UDP DNS'; fi
    else echo 'SKIP: public UDP DNS had no working baseline'; fi
    /sbin/pfctl -a '\#(anchor)' -vvs rules 2>/dev/null
    if ! RESULT=$("$TEST_ROOT/helper" verify "$IP" dns:1.1.1.1 2>&1); then printf 'FAIL: verification hold: %s\n' "$RESULT"; exit 0; fi
    if https --resolve "api.ipify.org:443:$IP" https://api.ipify.org 2>/dev/null; then echo 'PASS: verification HTTPS exception'; else echo 'FAIL: verification HTTPS exception'; fi
    if [ "$BASE_OTHER" = 1 ]; then
      if https --resolve "example.com:443:$OTHER" https://example.com 2>/dev/null; then echo 'FAIL: verification allowed unrelated HTTPS'; else echo 'PASS: verification stopped unrelated HTTPS'; fi
    else echo 'SKIP: unrelated HTTPS had no working baseline'; fi
    if [ "$BASE_DNS" = 1 ]; then
      if dns; then echo 'PASS: verification DNS exception'; else echo 'FAIL: verification DNS exception'; fi
    fi
    cleanup
    if [ "$("$TEST_ROOT/helper" status)" = inactive ]; then echo 'PASS: test anchor cleared'; else echo 'FAIL: test anchor still active'; fi
    if https --resolve "api.ipify.org:443:$IP" https://api.ipify.org 2>/dev/null; then echo 'PASS: HTTPS restored'; else echo 'FAIL: HTTPS not restored within three seconds'; fi
    echo 'IPv6 enforcement and application-proxy traffic require separate working baselines.'
    """#
    if CommandLine.arguments.contains("--dry-run") { print(script); exit(0) }
    do {
        let report = try await Privileged.run(script, prompt: "Test Whereabouts firewall for up to 40 seconds, then automatically restore internet access.")
        print(report)
        exit(runtimeReportFailed(report) ? 1 : 0)
    } catch {
        print("Live firewall test did not complete: \(error.localizedDescription)")
        exit(1)
    }
}

@MainActor func liveSleepTest() async {
    let script = #"""
    #!/bin/bash
    set -euo pipefail
    WAKE=$(/bin/date -v+40S '+%m/%d/%y %H:%M:%S')
    /usr/bin/pmset schedule wake "$WAKE" com.doxigo.Whereabouts.RuntimeTest
    echo "Scheduled test wake: $WAKE"
    /usr/bin/pmset -g sched
    if ! /usr/bin/pmset sleepnow; then
      /usr/bin/pmset schedule cancel wake "$WAKE" com.doxigo.Whereabouts.RuntimeTest
      exit 1
    fi
    """#
    if CommandLine.arguments.contains("--dry-run") { print(script); exit(0) }
    do {
        print(try await Privileged.run(script, prompt: "Put this Mac to sleep once and schedule a wake in 40 seconds to test Whereabouts recovery."))
        exit(0)
    } catch {
        print("Sleep test did not complete: \(error.localizedDescription)")
        exit(1)
    }
}
