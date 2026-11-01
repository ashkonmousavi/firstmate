import os, pathlib, time, unittest
fixture = pathlib.Path(os.environ['FM_EVAL_FIXTURE'])
(fixture / 'validation.pid').write_text(str(os.getpid()))
class SustainedValidation(unittest.TestCase):
    def test_sustained_arithmetic(self):
        # This is a real test workload, deliberately long enough to span restart.
        for i in range(6000):
            self.assertEqual(sum(range(100)), 4950)
            (fixture / 'validation-progress').write_text(str(i))
            time.sleep(0.1)
unittest.main()
