import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location("driver", Path(__file__).parents[1] / "src/app/driver.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class DriverTests(unittest.TestCase):
    def test_missing_or_failed_module_cannot_report_enabled(self):
        self.assertEqual(driver.state_from_values({"base": 1, "fade": -2}, {"global": 1}, 0xFFFFFFFF), "partial")
        self.assertEqual(driver.state_from_values({"base": 0}, {"global": 0}, 0), "native")
        self.assertEqual(driver.state_from_values({"base": 1}, {"global": 1}, 0xFFFFFFFF), "enabled")
        self.assertEqual(driver.state_from_values({"base": 1}, {"global": 1}, 0), "partial")

    def test_unsupported_host_rejected_before_debugger_import(self):
        with patch.object(driver, "run_command", return_value="different-build") as run:
            with self.assertRaisesRegex(RuntimeError, "Unsupported macOS"):
                driver.control("enable", Path("/unused"))
            self.assertEqual(run.call_count, 1)

    def test_sip_enabled_is_rejected_without_changes(self):
        with patch.object(driver, "run_command", side_effect=[driver.BUILD, driver.DOCK_UUID, "System Integrity Protection status: enabled."]):
            with self.assertRaisesRegex(RuntimeError, "requires SIP"):
                driver.preflight()

    def test_old_fade_rejected_before_loading_or_mutating(self):
        api = MagicMock()
        api.SBError.return_value.Fail.return_value = False
        process = api.debugger.CreateTarget.return_value.AttachToProcessWithID.return_value
        thread = MagicMock()
        thread.GetQueueName.return_value = "com.apple.main-thread"
        process.__iter__.side_effect = lambda: iter([thread])
        process.Detach.return_value.Fail.return_value = False
        expressions = []

        def evaluate(expression, options):
            expressions.append(expression)
            value = MagicMock()
            value.GetError.return_value.Fail.return_value = False
            value.GetValueAsUnsigned.return_value = int('"GenieCrossfadeV23Status"' in expression)
            return value

        thread.GetFrameAtIndex.return_value.EvaluateExpression.side_effect = evaluate
        with patch.dict("sys.modules", {"lldb": api}), patch.object(driver, "preflight", return_value=driver.BUILD), patch.object(driver, "run_command", return_value="123"):
            for action in ("enable", "disable"):
                with self.assertRaisesRegex(RuntimeError, "Restart Dock"):
                    driver.control(action, Path("/unused"))
        self.assertEqual(process.Detach.call_count, 2)
        self.assertTrue(all("dlsym" in expression for expression in expressions))

    def test_unknown_action_never_checks_host(self):
        with patch.object(driver, "preflight") as preflight:
            with self.assertRaises(ValueError):
                driver.control("arbitrary", Path("/unused"))
            preflight.assert_not_called()


if __name__ == "__main__":
    unittest.main()
