#!/usr/bin/env python3
"""Disposable native tasks-axi acceptance tests for the bound wrapper."""
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "bin/fm-tasks-axi.sh"
HELPER = ROOT / "bin/fm-request-acceptance.py"


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


class RequestCustody(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-request-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = pathlib.Path(self.temp.name)
        (self.home / "data").mkdir()
        (self.home / "state").mkdir()
        (self.home / ".tasks.toml").write_text('backend = "markdown"\n')
        (self.home / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT),
                        TASKS_AXI_BACKEND="markdown")

    def run_task(self, *args, ok=True):
        p = subprocess.run([str(WRAPPER), *map(str, args)], cwd=self.home, env=self.env,
                           capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0)
        return p

    def packet(self, *, task="owner-1", source="source-1", requirement="r1",
               text="Explain the result", kind="explanation", expected=None,
               restricted=False, safe_text=None):
        item = {
            "version": 1, "origin_home": str(self.home), "origin_task_id": task,
            "expected_body_sha256": expected, "interpretation_owner": "intake",
            "interpretation_complete": True,
            "sources": [{
                "session_id": "session-1", "message_uuid": source,
                "file_ref": "old-session.json", "source_custody": "restricted" if restricted else "complete",
                "full_text": None if restricted else text,
                "full_text_sha256": None if restricted else sha(text),
            }],
            "requirements": [{
                "id": requirement, "kind": kind, "source_message_uuid": source,
                "text_ref": None if restricted else text,
                "safe_text": safe_text, "source_binding": "verified_safe" if restricted and safe_text else
                    "restricted" if restricted else "verified_complete",
                "disposition": "pending", "proof_refs": [], "superseded_by": [],
                "proof_kind": "reply" if kind == "explanation" else "artifact_delivery",
                "acceptance_level": "source" if kind == "explanation" else "installed",
                **({} if kind == "explanation" else {"target_refs": ["report"], "delivered_path": "report.md"})
            }],
            "corrections": [],
        }
        return item

    def save(self, name, value):
        path = self.home / name
        path.write_text(json.dumps(value, ensure_ascii=False))
        path.chmod(0o600)
        return path

    def body(self, task="owner-1"):
        show = self.run_task("show", task, "--full").stdout
        p = subprocess.run([str(HELPER), "show-body", "--task-id", task],
                           input=show, text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def test_create_and_rotation_and_ordinary_preservation(self):
        packet = self.save("packet.json", self.packet(text="Explain café"))
        self.run_task("add", "owner-1", "Owner", "--owner-request-file", packet)
        original = self.body()
        self.assertIn("Explain café", original)
        (self.home / "old-session.json").write_text("Explain café")
        (self.home / "old-session.json").unlink()
        next_body = self.home / "next.md"
        next_body.write_text("Note\n\n" + original)
        self.run_task("update", "owner-1", "--body-file", next_body)
        self.assertIn("Note", self.body())
        self.assertIn("Explain café", self.body())
        next_body.write_text("erase")
        self.run_task("update", "owner-1", "--body-file", next_body, ok=False)
        self.run_task("update", "owner-1", "--body", "erase", ok=False)
        self.assertIn("Explain café", self.body())

    def test_correction_archives_and_rejects_stale_preimage(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("first.json", self.packet()))
        old = self.body()
        correction = self.packet(source="source-2", requirement="r2",
                                 text="Correct the explanation", expected=sha(old))
        correction["corrections"] = [{"id": "r1", "superseded_by": ["r2"]}]
        path = self.save("correction.json", correction)
        self.run_task("update", "owner-1", "--owner-request-file", path)
        body = self.body()
        self.assertIn('"superseded_by":["r2"]', body)
        self.assertIn("source-1", body)
        self.assertIn("source-2", body)
        archive = self.home / "data/note-archive.md"
        self.assertTrue(archive.exists())
        self.assertIn("source-1", archive.read_text())
        self.run_task("update", "owner-1", "--owner-request-file", path, ok=False)
        self.assertEqual(body, self.body())

    def test_mixed_safe_and_restricted_source_keeps_secret_out(self):
        secret = "CREDENTIAL-DO-NOT-COPY"
        packet = self.packet(restricted=True, safe_text="Write a public summary")
        packet["requirements"].append({
            "id": "r2", "kind": "action", "source_message_uuid": "source-1",
            "text_ref": None, "safe_text": None, "source_binding": "restricted",
            "disposition": "held", "proof_refs": [], "superseded_by": [],
            "proof_kind": "artifact_delivery", "acceptance_level": "installed",
            "target_refs": ["report"], "delivered_path": "report.md"
        })
        path = self.save("restricted.json", packet)
        result = self.run_task("add", "owner-1", "Owner", "--owner-request-file", path)
        body = self.body()
        self.assertNotIn(secret, body)
        self.assertNotIn(sha(secret), body)
        self.assertIn("Write a public summary", body)
        self.assertIn('"source_custody":"restricted"', body)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_bound_remote_receiver_preserves_full_body_on_readback(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("remote.json", self.packet()))
        original = self.body()
        target = self.home.parent / (self.home.name + "-remote")
        target.mkdir()
        self.addCleanup(lambda: __import__("shutil").rmtree(target, ignore_errors=True))
        for child in ("data", "state", "state/handoff", "bin"):
            (target / child).mkdir(exist_ok=True)
        (target / "AGENTS.md").write_text("fixture\n")
        (target / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
        delivered = target / "state/handoff/batch.outbox.md"
        payload = (self.home / "data/backlog.md").read_bytes()
        delivered.write_bytes(payload)
        generation = target / "state/handoff/.batch.upload-generation"
        generation.write_text(f"1\n{len(payload)}\n{hashlib.sha256(payload).hexdigest()}\n")
        env = dict(self.env, FM_HOME=str(target))
        receive = subprocess.run([str(ROOT / "bin/fm-backlog-receive.sh"),
                                  "state/handoff/batch.outbox.md", str(len(payload)),
                                  hashlib.sha256(payload).hexdigest(), "1"],
                                 env=env, cwd=target, capture_output=True, text=True)
        self.assertEqual(receive.returncode, 0, receive.stderr)
        shown = subprocess.run([str(WRAPPER), "show", "owner-1", "--full"],
                               env=env, cwd=target, capture_output=True, text=True)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        parsed = subprocess.run([str(HELPER), "show-body", "--task-id", "owner-1"],
                                input=shown.stdout, text=True, capture_output=True)
        self.assertEqual(parsed.stdout, original)
        self.assertFalse(delivered.exists())

    def test_captain_hold_answer_keeps_bound_request(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("captain.json", self.packet()))
        original = self.body()
        hold = subprocess.run([str(ROOT / "bin/fm-captain-hold.sh"), "hold", "owner-1",
                               "--reason", "Choose result"], env=self.env, cwd=self.home,
                              capture_output=True, text=True)
        self.assertEqual(hold.returncode, 0, hold.stderr)
        self.assertIn("source-1", self.body())
        answer = self.home / "decision.txt"
        answer.write_text("Proceed with the summary\n")
        resolved = subprocess.run([str(ROOT / "bin/fm-captain-hold.sh"), "answer", "owner-1",
                                   "--decision-file", str(answer)], env=self.env, cwd=self.home,
                                  capture_output=True, text=True)
        self.assertEqual(resolved.returncode, 0, resolved.stderr)
        self.assertIn("source-1", self.body())
        self.assertIn("Proceed with the summary", self.body())
        self.assertIn("Owner request acceptance v1", original)

    def test_real_retain_correction_race_refuses_stale_then_preserves_both(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("race-first.json", self.packet()))
        initial = self.body()
        correction = self.packet(source="source-2", requirement="r2",
                                 text="Corrected instruction", expected=sha(initial))
        correction["corrections"] = [{"id": "r1", "superseded_by": ["r2"]}]
        path = self.save("race-correction.json", correction)
        real = subprocess.check_output(["which", "tasks-axi"], text=True).strip()
        fakebin = self.home / "fakebin"
        fakebin.mkdir()
        shim = fakebin / "tasks-axi"
        shim.write_text("#!/usr/bin/env bash\n"
                        "if [ \"$1\" = show ] && mkdir \"$FM_RACE_ONCE\" 2>/dev/null; then\n"
                        "  touch \"$FM_RACE_ENTERED\"\n"
                        "  while [ ! -f \"$FM_RACE_RELEASE\" ]; do sleep .02; done\n"
                        "fi\n"
                        f"exec {real} \"$@\"\n")
        shim.chmod(0o755)
        env = dict(self.env, STATE=str(self.home / "state"),
                   FM_RACE_ONCE=str(self.home / "once"),
                   FM_RACE_ENTERED=str(self.home / "entered"),
                   FM_RACE_RELEASE=str(self.home / "release"),
                   PATH=str(fakebin) + os.pathsep + self.env["PATH"])
        intake = subprocess.Popen([str(WRAPPER), "update", "owner-1", "--owner-request-file", str(path)],
                                  cwd=self.home, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            import time
            deadline = time.monotonic() + 8
            while not (self.home / "entered").exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.home / "entered").exists(), "correction never entered native read")
            shell = '. "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_retain "$2/data" owner-1 --note ready'
            retain = subprocess.Popen(["bash", "-c", shell, "_", str(ROOT), str(self.home)],
                                      cwd=self.home, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            (self.home / "release").touch()
            intake_out, intake_err = intake.communicate(timeout=15)
            self.assertEqual(intake.returncode, 0, intake_err)
            retain_out, retain_err = retain.communicate(timeout=15)
            self.assertEqual(retain.returncode, 0, retain_err)
            final = self.body()
            self.assertIn("ready", final)
            self.assertIn("source-2", final)
        finally:
            (self.home / "release").touch()
            if intake.poll() is None:
                intake.terminate()
                intake.communicate(timeout=5)


    def test_unrelated_serialized_handoffs_both_survive(self):
        self.run_task("add", "scope-a", "A")
        target = self.home.parent / (self.home.name + "-secondmate")
        target.mkdir()
        self.addCleanup(lambda: __import__("shutil").rmtree(target, ignore_errors=True))
        for child in ("data", "state", "config", "projects", "bin"):
            (target / child).mkdir()
        (target / "AGENTS.md").write_text("fixture\n")
        (target / ".fm-secondmate-home").write_text("design\n")
        (target / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
        (self.home / "data/secondmates.md").write_text(
            f"- design - feature work (home: {target}; scope: feature work; projects: alpha; added 2026-07-09)\n")
        (self.home / "state/design.meta").write_text(
            f"window=firstmate:fm-design\nkind=secondmate\nharness=claude\nbackend=tmux\nhome={target}\nworktree={target}\n")
        fakebin = self.home / "handoff-fakebin"
        fakebin.mkdir()
        tmux = fakebin / "tmux"
        tmux.write_text('#!/usr/bin/env bash\ncase "$1" in list-windows) echo fm-design;; capture-pane) printf "❯\\n";; display-message) echo firstmate;; *) exit 0;; esac\n')
        tmux.chmod(0o755)
        real = subprocess.check_output(["which", "tasks-axi"], text=True).strip()
        shim = fakebin / "tasks-axi"
        shim.write_text("#!/usr/bin/env bash\n"
                        "if [ \"$1\" = mv ] && [ \"$2\" = scope-a ] && mkdir \"$FM_HANDOFF_ONCE\" 2>/dev/null; then\n"
                        "  touch \"$FM_HANDOFF_ENTERED\"\n"
                        "  while [ ! -f \"$FM_HANDOFF_RELEASE\" ]; do sleep .02; done\n"
                        "fi\n"
                        f"exec {real} \"$@\"\n")
        shim.chmod(0o755)
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + self.env["PATH"],
                   FM_HANDOFF_ONCE=str(self.home / "move-once"),
                   FM_HANDOFF_ENTERED=str(self.home / "move-entered"),
                   FM_HANDOFF_RELEASE=str(self.home / "move-release"),
                   FM_SEND_SETTLE="0", FM_SEND_SLEEP="0", FM_SEND_RETRIES="1")
        a = subprocess.Popen([str(ROOT / "bin/fm-backlog-handoff.sh"), "design", "scope-a"],
                             cwd=self.home, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            import time
            deadline = time.monotonic() + 15
            while not (self.home / "move-entered").exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.home / "move-entered").exists(), "first handoff never reached native move")
            self.run_task("add", "scope-b", "B")
            b = subprocess.Popen([str(ROOT / "bin/fm-backlog-handoff.sh"), "design", "scope-b"],
                                 cwd=self.home, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(.2)
            (self.home / "move-release").touch()
            ao, ae = a.communicate(timeout=30)
            bo, be = b.communicate(timeout=30)
            self.assertEqual(a.returncode, 0, ao + ae)
            self.assertEqual(b.returncode, 0, bo + be)
            target_body = (target / "data/backlog.md").read_text()
            self.assertEqual(target_body.count("scope-a - A"), 1)
            self.assertEqual(target_body.count("scope-b - B"), 1)
        finally:
            (self.home / "move-release").touch()
            if a.poll() is None:
                a.terminate()
                a.communicate(timeout=5)

    def test_same_task_correction_while_handoff_waits_refuses_stale_source(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("handoff-first.json", self.packet()))
        old = self.body()
        correction = self.packet(source="source-2", requirement="r2", text="Corrected intent", expected=sha(old))
        correction["corrections"] = [{"id": "r1", "superseded_by": ["r2"]}]
        packet_path = self.save("handoff-correction.json", correction)
        target = self.home.parent / (self.home.name + "-waiting-target")
        target.mkdir()
        self.addCleanup(lambda: __import__("shutil").rmtree(target, ignore_errors=True))
        for child in ("data", "state", "config", "projects", "bin"):
            (target / child).mkdir()
        (target / "AGENTS.md").write_text("fixture\n")
        (target / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
        real = subprocess.check_output(["which", "tasks-axi"], text=True).strip()
        fakebin = self.home / "correction-fakebin"
        fakebin.mkdir()
        shim = fakebin / "tasks-axi"
        shim.write_text("#!/usr/bin/env bash\n"
                        "if [ \"$1\" = show ] && mkdir \"$FM_CORRECTION_ONCE\" 2>/dev/null; then\n"
                        "  touch \"$FM_CORRECTION_ENTERED\"\n"
                        "  while [ ! -f \"$FM_CORRECTION_RELEASE\" ]; do sleep .02; done\n"
                        "fi\n"
                        f"exec {real} \"$@\"\n")
        shim.chmod(0o755)
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + self.env["PATH"],
                   FM_CORRECTION_ONCE=str(self.home / "correction-once"),
                   FM_CORRECTION_ENTERED=str(self.home / "correction-entered"),
                   FM_CORRECTION_RELEASE=str(self.home / "correction-release"))
        intake = subprocess.Popen([str(WRAPPER), "update", "owner-1", "--owner-request-file", str(packet_path)],
                                  cwd=self.home, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            import time
            deadline = time.monotonic() + 15
            while not (self.home / "correction-entered").exists() and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertTrue((self.home / "correction-entered").exists(), "correction never entered native read")
            handoff = subprocess.Popen([str(ROOT / "bin/fm-backlog-handoff.sh"), "--to", str(target), "owner-1"],
                                       cwd=self.home, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            time.sleep(.2)
            (self.home / "correction-release").touch()
            io, ie = intake.communicate(timeout=20)
            self.assertEqual(intake.returncode, 0, io + ie)
            ho, he = handoff.communicate(timeout=20)
            self.assertNotEqual(handoff.returncode, 0, ho + he)
            self.assertIn("task owner-1 changed before locked handoff", he)
            self.assertIn("source-2", self.body())
            self.assertNotIn("owner-1", (target / "data/backlog.md").read_text())
        finally:
            (self.home / "correction-release").touch()
            if intake.poll() is None:
                intake.terminate()
                intake.communicate(timeout=5)

    def test_bound_local_transfer_keeps_full_section_and_source_close(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("transfer.json", self.packet()))
        original = self.body()
        target = self.home.parent / (self.home.name + "-receiver")
        target.mkdir()
        self.addCleanup(lambda: __import__("shutil").rmtree(target, ignore_errors=True))
        for child in ("data", "state", "config", "projects", "bin"):
            (target / child).mkdir()
        (target / "AGENTS.md").write_text("fixture\n")
        (target / ".fm-secondmate-home").write_text("receiver\n")
        (target / "data/backlog.md").write_text("## In flight\n\n## Queued\n\n## Done\n")
        moved = subprocess.run([str(ROOT / "bin/fm-backlog-handoff.sh"), "--to", str(target), "owner-1"],
                               env=self.env, cwd=self.home, capture_output=True, text=True)
        self.assertEqual(moved.returncode, 0, moved.stderr)
        receive_env = dict(self.env, FM_HOME=str(target))
        shown = subprocess.run([str(WRAPPER), "show", "owner-1", "--full"], env=receive_env,
                               cwd=target, capture_output=True, text=True)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        parsed = subprocess.run([str(HELPER), "show-body", "--task-id", "owner-1"],
                                input=shown.stdout, text=True, capture_output=True)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        self.assertEqual(parsed.stdout, original)
        self.assertIn("moved to", (self.home / "data/backlog.md").read_text())

    def test_ordinary_update_cannot_create_a_bound_section(self):
        self.run_task("add", "owner-1", "Owner")
        forged = self.home / "forged.md"
        forged.write_text("note\n\n```Owner request acceptance v1\n{}\n```\n")
        self.run_task("update", "owner-1", "--body-file", forged, ok=False)
        self.assertNotIn("Owner request acceptance v1", self.body())

    def test_native_done_does_not_accept_pending_requirement(self):
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("pending-done.json", self.packet()))
        self.run_task("done", "owner-1")
        body = self.body()
        self.assertIn('"disposition":"pending"', body)
        self.assertNotIn('"disposition":"accepted"', body)

    def test_explanation_requires_delivered_reply_reference(self):
        packet = self.packet()
        requirement = packet["requirements"][0]
        requirement["disposition"] = "accepted"
        requirement["proof_refs"] = [{"source_owner": "installation", "receipt_id": "receipt-1",
                                      "content_sha256": sha("receipt") }]
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("wrong-reply.json", packet), ok=False)
        requirement["proof_refs"][0]["source_owner"] = "reply"
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("reply.json", packet))
        self.assertIn('"proof_kind":"reply"', self.body())

    def test_secret_bearing_source_is_refused_without_echo_or_hash(self):
        secret = "PRIVATE-CREDENTIAL-EXAMPLE"
        packet = self.packet(restricted=True, safe_text="Write a public summary")
        packet["sources"][0]["full_text"] = secret
        packet["sources"][0]["full_text_sha256"] = sha(secret)
        result = self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                               self.save("bad-secret.json", packet), ok=False)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertNotIn(sha(secret), result.stdout + result.stderr)
        self.run_task("show", "owner-1", "--full", ok=False)

    def test_nonproduct_action_has_no_fake_release_identity(self):
        packet = self.packet(kind="action", text="Publish the report")
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("artifact.json", packet))
        body = self.body()
        self.assertIn('"proof_kind":"artifact_delivery"', body)
        self.assertNotIn("fix_commit", body)
        self.assertNotIn("deployed_receipt_ref", body)

    def test_failed_native_full_readback_reports_unconfirmed_write(self):
        packet = self.save("readback.json", self.packet())
        real = subprocess.check_output(["which", "tasks-axi"], text=True).strip()
        fakebin = self.home / "readback-bin"
        fakebin.mkdir()
        shim = fakebin / "tasks-axi"
        shim.write_text("#!/usr/bin/env bash\n"
                        "if [ \"$1\" = show ]; then printf 'task:\n  id: wrong-id\n  body: \"-\"\n'; exit 0; fi\n"
                        f"exec {real} \"$@\"\n")
        shim.chmod(0o755)
        env = dict(self.env, PATH=str(fakebin) + os.pathsep + self.env["PATH"])
        result = subprocess.run([str(WRAPPER), "add", "owner-1", "Owner", "--owner-request-file", str(packet)],
                                env=env, cwd=self.home, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unconfirmed", result.stderr)
        self.assertIn("Owner request acceptance v1", self.body())

    def test_structural_validator_rejects_truncated_section_and_unproved_acceptance(self):
        packet = self.packet()
        packet["requirements"][0]["disposition"] = "accepted"
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("unproved.json", packet), ok=False)
        packet["requirements"][0]["disposition"] = "pending"
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("pending.json", packet))
        body = self.body()
        truncated = self.home / "truncated.md"
        truncated.write_text(body[:-4])
        result = subprocess.run([str(HELPER), "validate", "--body-file", str(truncated),
                                 "--task-id", "owner-1", "--home", str(self.home)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("truncated", result.stderr)

    def test_malformed_duplicate_and_wrong_identity_refuse_without_write(self):
        packet = self.packet()
        packet["origin_task_id"] = "other"
        self.run_task("add", "owner-1", "Owner", "--owner-request-file",
                      self.save("wrong.json", packet), ok=False)
        packet["origin_task_id"] = "owner-1"
        malformed = self.home / "dup.json"
        malformed.write_text(json.dumps(packet)[:-1] + ', "version": 1}')
        malformed.chmod(0o600)
        self.run_task("add", "owner-1", "Owner", "--owner-request-file", malformed, ok=False)
        self.run_task("show", "owner-1", "--full", ok=False)


if __name__ == "__main__":
    unittest.main()
