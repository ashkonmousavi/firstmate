#!/usr/bin/env python3
import importlib.util
import io
import json
import socket
import time
import unittest
from pathlib import Path
from unittest import mock


READER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-eventwait.py"
SPEC = importlib.util.spec_from_file_location("herdr_eventwait", READER_PATH)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class FailingSocket:
    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        raise OSError("receive failed")


class ClosingStreamSocket:
    def __init__(self):
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b"",
        ]

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, _request):
        pass

    def recv(self, _size):
        return self.chunks.pop(0)


class RejectedSubscriptionSocket(ClosingStreamSocket):
    def __init__(self):
        self.chunks = [b'{"result":{"type":"not_started"}}\n']


class SubscribeReplySocket:
    """One fake connection that answers the subscribe request it receives.

    Herdr rejects a whole subscription when any named pane is gone; the error
    line is the exact shape captured from herdr 0.9.1 (protocol 22). Every
    request sent over any connection is appended to `requests`."""

    def __init__(self, gone, requests):
        self.gone = gone
        self.requests = requests
        self.reply = None
        self.closed = False

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, request):
        panes = [
            sub["pane_id"]
            for sub in json.loads(request.decode("utf-8"))["params"]["subscriptions"]
        ]
        self.requests.append(panes)
        missing = [pane for pane in panes if pane in self.gone]
        if missing:
            self.reply = (
                '{"id":"fm-eventwait","error":{"code":"pane_not_found",'
                '"message":"pane %s not found"}}\n' % missing[0]
            ).encode("utf-8")
        else:
            self.reply = b'{"id":"fm-eventwait","result":{"type":"subscription_started"}}\n'

    def recv(self, _size):
        if self.reply is not None:
            reply, self.reply = self.reply, None
            return reply
        raise socket.timeout()

    def close(self):
        self.closed = True


def run_reader(gone, panes):
    requests = []
    stdout = io.StringIO()
    factory = lambda *_args: SubscribeReplySocket(gone, requests)
    with mock.patch.object(READER.socket, "socket", side_effect=factory):
        with mock.patch.object(READER.sys, "stdout", stdout):
            with mock.patch.object(READER.sys, "stderr", io.StringIO()):
                result = READER.main(["herdr-eventwait.py", "socket", "0.2"] + panes)
    return result, stdout.getvalue(), requests


class EventWaitGonePaneTest(unittest.TestCase):
    def test_gone_pane_is_dropped_and_live_panes_still_subscribe(self):
        result, out, requests = run_reader({"wJP:pAW"}, ["wK8:p93", "wJP:pAW", "wK8:p98"])

        self.assertEqual(result, 0)
        self.assertEqual(out, "@subscribed\n")
        self.assertEqual(requests[0], ["wK8:p93", "wJP:pAW", "wK8:p98"])
        self.assertEqual(requests[-1], ["wK8:p93", "wK8:p98"])

    def test_every_gone_pane_is_dropped(self):
        gone = {"wJP:pAW", "wJP:pB2", "wKA:p2"}
        result, out, requests = run_reader(gone, ["wJP:pAW", "wK8:p93", "wJP:pB2", "wKA:p2"])

        self.assertEqual(result, 0)
        self.assertEqual(out, "@subscribed\n")
        self.assertEqual(requests[-1], ["wK8:p93"])
        self.assertEqual(len(requests), 4)

    def test_pane_id_prefix_is_not_mistaken_for_the_gone_pane(self):
        result, _out, requests = run_reader({"wJP:pAW"}, ["wJP:pA", "wJP:pAW"])

        self.assertEqual(result, 0)
        self.assertEqual(requests[-1], ["wJP:pA"])

    def test_all_panes_gone_reports_no_subscription(self):
        result, out, _requests = run_reader({"wJP:pAW", "wKA:p5"}, ["wJP:pAW", "wKA:p5"])

        self.assertEqual(result, 3)
        self.assertEqual(out, "")

    def test_unrecognized_rejection_still_reports_no_subscription(self):
        result, out, requests = run_reader({"other:pane"}, ["wK8:p93"])

        self.assertEqual(result, 0)
        self.assertEqual(requests, [["wK8:p93"]])
        self.assertEqual(out, "@subscribed\n")

        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", io.StringIO()) as stdout:
                rejected = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])
        self.assertEqual(rejected, 3)
        self.assertEqual(stdout.getvalue(), "")


class EventWaitReadLineTest(unittest.TestCase):
    def test_deadline_is_clean_timeout(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        line, buf, outcome = READER._read_line(left, b"", time.monotonic())

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "timeout")

    def test_peer_closure_is_runtime_failure(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        right.close()

        line, buf, outcome = READER._read_line(
            left, b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "closed")

    def test_receive_error_is_runtime_failure(self):
        line, buf, outcome = READER._read_line(
            FailingSocket(), b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "error")

    def test_main_reports_early_stream_closure(self):
        stdout = io.StringIO()
        with mock.patch.object(READER.socket, "socket", return_value=ClosingStreamSocket()):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 4)
        self.assertEqual(stdout.getvalue(), "@subscribed\n")

    def test_main_does_not_signal_readiness_before_valid_ack(self):
        stdout = io.StringIO()
        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 3)
        self.assertEqual(stdout.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
