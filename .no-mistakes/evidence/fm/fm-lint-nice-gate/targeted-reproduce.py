from pathlib import Path
import os, subprocess, tempfile
root = Path.cwd()
evidence = Path(__file__).parent
with tempfile.TemporaryDirectory(prefix=".gate-targeted-", dir=root) as td:
    env = dict(os.environ, TMPDIR=td)
    for subject, delimiter, calls in [
        ("fm-pi-watch-extension", "\ntest_pi_extension_reports_external_healthy_watcher\n", "test_opencode_watch_arm_coordinates_with_turnend_guard\ntest_opencode_healthy_arm_output_does_not_suppress_guard\n"),
        ("fm-remote-job-launchagent", "\ntest_reload_lock_publication_race || exit 1", "test_reload_lock_publication_race || exit 1\n"),
    ]:
        source = root / "tests" / (subject + ".test.sh")
        driver = root / "tests" / (".gate-" + subject + ".sh")
        try:
            driver.write_text(source.read_text().split(delimiter, 1)[0] + "\n" + calls)
            subprocess.run(["timeout", "60", "bash", str(driver)], env=env, check=True)
        finally:
            driver.unlink(missing_ok=True)
