"""Behavior tests without router access; all system commands use temp fixtures."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "files/usr/lib/tr3000-switch/core.sh"
SHELL = shlex.split(os.environ.get("TEST_SHELL", "/bin/sh"))


class SwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trswitch-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.run_dir = self.base / "runtime"
        self.run_dir.mkdir()
        self.bin_dir = self.base / "bin"
        self.bin_dir.mkdir()
        self.gpio = self.base / "gpio"
        self.config = self.base / "uci.json"
        self.actions = self.base / "actions.log"
        self.action = self.base / "action with spaces.sh"
        self.action.write_text('#!/bin/sh\nprintf "%s:%s:%s\\n" "$1" "$TR3000_SWITCH_STATE" "$TR3000_SWITCH_PREVIOUS" >> "$ACTION_LOG"\n')
        self.action.chmod(0o700)
        self.values = {
            "tr3000-switch.main.enabled": "1",
            "tr3000-switch.main.action": str(self.action),
            "tr3000-switch.main.retry_seconds": "1",
            "tr3000-switch.main.action_timeout": "2",
        }
        self.save_config()
        self.env = dict(os.environ, RUN_DIR=str(self.run_dir), GPIO_FILE=str(self.gpio),
                        CORE=str(CORE), MOCK_UCI=str(self.config), ACTION_LOG=str(self.actions),
                        PATH=str(self.bin_dir) + os.pathsep + os.environ["PATH"])
        self.mock("uci", f"#!{sys.executable}\n" + '''import json, os, sys
args = [a for a in sys.argv[1:] if a != '-q']
data = json.load(open(os.environ['MOCK_UCI']))
if args[0] == 'get' and args[1] in data:
    print(data[args[1]])
else:
    sys.exit(1)
''')
        self.mock("logger", "#!/bin/sh\nexit 0\n")
        self.mock("mount", "#!/bin/sh\nexit 1\n")
        # macOS lacks timeout. On Linux/CI, exercise its real timeout command.
        if not shutil.which("timeout"):
            self.mock("timeout", f"#!{sys.executable}\n" + '''import subprocess, sys
try:
    result = subprocess.run(sys.argv[2:], timeout=float(sys.argv[1]))
    sys.exit(result.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
''')
        # Only rewrite the installed library location; test the real CLI/daemon.
        self.cli = self.base / "tr3000-switch"
        self.cli.write_text((ROOT / "files/usr/sbin/tr3000-switch").read_text().replace(
            ". /usr/lib/tr3000-switch/core.sh", '. "$CORE"'))

    def mock(self, name, text):
        path = self.bin_dir / name
        path.write_text(text)
        path.chmod(0o700)

    def save_config(self):
        self.config.write_text(json.dumps(self.values))

    def sh(self, code, check=True):
        result = subprocess.run(SHELL + ["-c", '. "$CORE"\n' + code], env=self.env,
                                capture_output=True, text=True, timeout=12)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def command(self, *args, check=True):
        result = subprocess.run(SHELL + [str(self.cli), *args], env=self.env,
                                capture_output=True, text=True, timeout=12)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def gpio_state(self, state, number=512, active_low=True, label="mode"):
        level = "lo" if (state == "on") == active_low else "hi"
        tmp = self.gpio.with_suffix(".new")
        tmp.write_text(f"gpiochip0: GPIOs 512-568, parent: platform/pinctrl\n"
                       f" gpio-{number} (                    |{label}                ) in {level} IRQ"
                       + (" ACTIVE LOW" if active_low else "") + "\n")
        tmp.replace(self.gpio)

    def start_daemon(self):
        process = subprocess.Popen(SHELL + [str(self.cli), "daemon"], env=self.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def cleanup():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        self.addCleanup(cleanup)
        return process

    def wait_for(self, predicate, seconds=8):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("Timed out waiting for state")

    def lines(self):
        return self.actions.read_text().splitlines() if self.actions.exists() else []

    def test_gpio_polarity_and_dynamic_number(self):
        for state in ["on", "off"]:
            for active_low in [True, False]:
                for number in [0, 512, 640]:
                    self.gpio_state(state, number, active_low)
                    self.assertEqual(self.sh('GPIO_LABEL=mode; read_gpio').stdout.strip(), state)

    def test_ambiguous_gpio_is_not_guessed(self):
        self.gpio_state("on")
        self.gpio.write_text(self.gpio.read_text() * 2)
        self.assertNotEqual(self.sh('GPIO_LABEL=mode; read_gpio', check=False).returncode, 0)

    def test_missing_or_wrong_gpio_is_not_guessed(self):
        for fixture in ["", "gpio-512 ( | other ) in lo IRQ ACTIVE LOW\n", "gpio-512 ( | mode ) in unknown\n"]:
            self.gpio.write_text(fixture)
            self.assertNotEqual(self.sh('GPIO_LABEL=mode; read_gpio', check=False).returncode, 0)

    def test_gpio_takes_precedence_and_invert_applies_once(self):
        self.gpio_state("on")
        (self.run_dir / "event").write_text("off\n")
        self.assertEqual(self.sh('load_settings; physical_state').stdout.strip(), "on")
        self.values["tr3000-switch.main.invert"] = "1"
        self.save_config()
        self.assertEqual(self.sh('load_settings; physical_state').stdout.strip(), "off")

    def test_event_fallback_and_unknown_boot(self):
        self.assertNotEqual(self.sh('load_settings; physical_state', check=False).returncode, 0)
        (self.run_dir / "event").write_text("on\n")
        self.assertEqual(self.sh('load_settings; physical_state').stdout.strip(), "on")

    def test_unsupported_events_are_ignored(self):
        self.env.update(BUTTON="reset", ACTION="pressed")
        self.command("event")
        self.assertFalse((self.run_dir / "event").exists())
        self.env.update(BUTTON="BTN_0", ACTION="pressed")
        self.command("event")
        self.assertEqual((self.run_dir / "event").read_text().strip(), "on")
        self.env["ACTION"] = "released"
        self.command("event")
        self.assertEqual((self.run_dir / "event").read_text().strip(), "off")

    def test_disabled_event_ignored(self):
        self.values["tr3000-switch.main.enabled"] = "0"
        self.save_config()
        self.env.update(BUTTON="BTN_0", ACTION="pressed")
        self.command("event")
        self.assertFalse((self.run_dir / "event").exists())

    def test_universal_adapter_arguments_and_spaces(self):
        self.command("run", "on")
        self.command("run", "off")
        self.assertEqual(self.lines(), ["on:on:unknown", "off:off:on"])
        self.assertEqual((self.run_dir / "applied").read_text().strip(), "off")

    def test_action_path_is_not_evaluated(self):
        malicious = str(self.action) + "; touch " + str(self.base / "injected")
        self.values["tr3000-switch.main.action"] = malicious
        self.save_config()
        self.assertNotEqual(self.command("run", "on", check=False).returncode, 0)
        self.assertFalse((self.base / "injected").exists())

    def test_failure_preserves_last_success(self):
        self.command("run", "off")
        self.action.write_text("#!/bin/sh\nexit 7\n")
        result = self.command("run", "on", check=False)
        self.assertEqual(result.returncode, 7)
        self.assertEqual((self.run_dir / "applied").read_text().strip(), "off")
        self.assertEqual((self.run_dir / "status").read_text().strip(), "error")

    def test_timeout_marks_failure(self):
        self.values["tr3000-switch.main.action_timeout"] = "1"
        self.save_config()
        self.action.write_text("#!/bin/sh\nexec sleep 3\n")
        self.assertNotEqual(self.command("run", "on", check=False).returncode, 0)
        self.assertFalse((self.run_dir / "applied").exists())

    def test_configuration_validation(self):
        for key, value in [("poll_seconds", "0"), ("stable_samples", "-1"),
                           ("invert", "yes"), ("check_interval", "abc"),
                           ("action", "relative.sh")]:
            with self.subTest(key=key):
                old = self.values.get("tr3000-switch.main." + key)
                self.values["tr3000-switch.main." + key] = value
                self.save_config()
                self.assertNotEqual(self.sh("load_settings", check=False).returncode, 0)
                if old is None:
                    del self.values["tr3000-switch.main." + key]
                else:
                    self.values["tr3000-switch.main." + key] = old

    def test_daemon_boot_dedup_override_and_auto(self):
        self.gpio_state("off")
        process = self.start_daemon()
        self.wait_for(lambda: len(self.lines()) == 1)
        time.sleep(2.1)
        self.assertEqual(self.lines(), ["off:off:unknown"])
        self.command("on")
        self.wait_for(lambda: len(self.lines()) == 2)
        self.assertEqual(self.lines()[-1], "on:on:off")
        self.command("auto")
        self.wait_for(lambda: len(self.lines()) == 3)
        self.assertEqual(self.lines()[-1], "off:off:on")
        self.assertNotEqual(self.command("run", "on", check=False).returncode, 0)
        self.assertIsNone(process.poll())

    def test_debounce_discards_short_pulse(self):
        self.gpio_state("off")
        self.start_daemon()
        self.wait_for(lambda: len(self.lines()) == 1)
        self.gpio_state("on")
        time.sleep(0.15)
        self.gpio_state("off")
        time.sleep(2.2)
        self.assertEqual(len(self.lines()), 1)
        self.gpio_state("on")
        self.wait_for(lambda: len(self.lines()) == 2)

    def test_daemon_retries_failed_action(self):
        self.gpio_state("on")
        self.action.write_text('#!/bin/sh\nif [ ! -f "$ACTION_LOG" ]; then echo fail > "$ACTION_LOG"; exit 9; fi\necho "$1" >> "$ACTION_LOG"\n')
        self.start_daemon()
        self.wait_for(lambda: self.lines() == ["fail", "on"])
        self.wait_for(lambda: (self.run_dir / "status").read_text().strip() == "ready")

    def test_worker_lock_prevents_concurrent_actions(self):
        self.sh('runtime_init; mkdir "$RUN_DIR/worker.lock"')
        (self.run_dir / "worker.lock/owner").write_text(str(os.getpid()))
        self.assertNotEqual(self.command("run", "on", check=False).returncode, 0)
        self.assertEqual(self.lines(), [])

    def test_health_check_reapplies_current_position(self):
        self.values['tr3000-switch.main.check_interval'] = '1'
        self.save_config()
        self.action.write_text('''#!/bin/sh
if [ "$1" = check ]; then exit 1; fi
echo "$1" >> "$ACTION_LOG"
''')
        self.gpio_state('on')
        self.start_daemon()
        self.wait_for(lambda: len(self.lines()) >= 2)
        self.assertEqual(self.lines()[:2], ['on', 'on'])

    def test_latest_position_is_applied_after_slow_action(self):
        self.values['tr3000-switch.main.action_timeout'] = '5'
        self.save_config()
        self.action.write_text('''#!/bin/sh
echo "start-$1" >> "$ACTION_LOG"
if [ "$1" = on ]; then sleep 2; fi
echo "end-$1" >> "$ACTION_LOG"
''')
        self.gpio_state('on')
        self.start_daemon()
        self.wait_for(lambda: self.lines() == ['start-on'])
        self.gpio_state('off')
        self.wait_for(lambda: len(self.lines()) == 4)
        self.assertEqual(self.lines(), ['start-on', 'end-on', 'start-off', 'end-off'])

    def test_unknown_boot_does_not_run_an_action(self):
        self.start_daemon()
        time.sleep(2.2)
        self.assertEqual(self.lines(), [])
        self.env.update(BUTTON="BTN_0", ACTION="released")
        self.command("event")
        self.wait_for(lambda: len(self.lines()) == 1)
        self.assertTrue(self.lines()[0].startswith("off:"))


class WireGuardTests(SwitchTests):
    # Do not inherit all controller tests a second time (filtered below).
    def setUp(self):
        super().setUp()
        self.wg_lib = self.base / "wireguard-lib.sh"
        self.wg_lib.write_text((ROOT / "examples/wireguard/lib.sh").read_text().replace(
            ". /usr/lib/tr3000-switch/core.sh", '. "$CORE"'))
        self.env["WG_LIB"] = str(self.wg_lib)

    def wg_sh(self, code, check=True):
        prelude = '. "$WG_LIB"\nRUN_DIR="$TEST_RUN_DIR"\nruntime_init\nWG_IF=trwg\nLAN_DEV=br-lan\nVPN_DNS="1.1.1.1 9.9.9.9"\nHANDSHAKE_TIMEOUT=1\n'
        self.env["TEST_RUN_DIR"] = str(self.run_dir)
        return self.sh(prelude + code, check=check)

    def test_wg_failed_handshake_keeps_guard(self):
        result = self.wg_sh('''
vpn_preflight() { return 0; }
guard_on() { echo guard-on; }
guard_off() { echo GUARD-REMOVED; }
interface_up() { return 0; }
handshake_ok() { return 1; }
sleep() { :; }
vpn_on
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guard-on", result.stdout)
        self.assertNotIn("GUARD-REMOVED", result.stdout)
        self.assertIn("nameserver 1.1.1.1", (self.run_dir / "resolv.conf").read_text())

    def test_wg_off_orders_down_dns_and_guard(self):
        result = self.wg_sh('''
cfg() { echo 1; }
ifdown() { echo down; }
ip() { return 1; }
sync_dns() { echo dns-off; }
guard_off() { echo guard-off; }
vpn_off
''')
        self.assertEqual(result.stdout.splitlines(), ["down", "dns-off", "guard-off"])

    def test_wg_failed_ifdown_does_not_remove_guard(self):
        result = self.wg_sh('''
cfg() { echo 1; }
ifdown() { return 1; }
guard_off() { echo GUARD-REMOVED; }
vpn_off
''', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("GUARD-REMOVED", result.stdout)

    def test_wg_dns_switch_and_wan_refresh(self):
        source = self.base / "wan-resolv"
        source.write_text("nameserver 192.0.2.53\n")
        self.env["TEST_AUTO_RESOLV"] = str(source)
        self.wg_sh('AUTO_RESOLV="$TEST_AUTO_RESOLV"; sync_dns on; sync_dns off')
        self.assertEqual((self.run_dir / "resolv.conf").read_text(), source.read_text())

    def test_wg_ipv4_validation(self):
        for address in ["1.1.1.1", "10.0.0.53"]:
            self.wg_sh(f"valid_ip_literal {shlex.quote(address)}")
        for address in ["256.1.1.1", "1.1.1", "x.0.0.1", "1..1.1", "1.1.1.1;touch x"]:
            self.assertNotEqual(self.wg_sh(f"valid_ip_literal {shlex.quote(address)}", check=False).returncode, 0)


def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite(loader.loadTestsFromTestCase(SwitchTests))
    suite.addTests(WireGuardTests(name) for name in dir(WireGuardTests) if name.startswith("test_wg_"))
    return suite


if __name__ == "__main__":
    unittest.main()
