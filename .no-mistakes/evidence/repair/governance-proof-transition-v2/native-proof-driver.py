import importlib.util, json, pathlib, sys, unittest
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('custody', root / 'tests/test_request_acceptance.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
original = m.RequestCustody.run_task

def traced(self, *args, **kwargs):
    print('\nCLI: fm-tasks-axi.sh ' + ' '.join(map(str, args)), flush=True)
    if '--owner-request-file' in args:
        packet = pathlib.Path(args[args.index('--owner-request-file') + 1])
        print('PACKET: ' + packet.read_text(), flush=True)
    result = original(self, *args, **kwargs)
    print('EXIT:', result.returncode, '\nSTDOUT:', result.stdout, '\nSTDERR:', result.stderr, flush=True)
    return result
m.RequestCustody.run_task = traced
names = ['test_product_proof_update_completes_refreshes_and_invalidates_release',
         'test_proof_update_refreshes_same_receipt_path_with_native_archive',
         'test_proof_updates_refuse_held_superseded_collision_and_stale_preimage']
suite = unittest.TestSuite(m.RequestCustody(name) for name in names)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
