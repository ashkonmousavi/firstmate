import importlib.util, os, pathlib, subprocess, unittest
root=pathlib.Path.cwd()
spec=importlib.util.spec_from_file_location('backstop_cases',root/'tests/fm-main-backstop.test.py')
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
real_run=subprocess.run
def baseline_run(argv,*args,**kwargs):
    if isinstance(argv,list):
        argv=[str(root/'.test-exit76/fm-main-backstop.py') if x==str(root/'bin/fm-main-backstop.py') else x for x in argv]
    return real_run(argv,*args,**kwargs)
subprocess.run=baseline_run
suite=unittest.TestSuite(mod.Backstop(name) for name in ['test_preempted_delta_read_reissues_same_cursor_and_progresses','test_permanently_preempted_delta_read_fails_boundedly'])
result=unittest.TextTestRunner(verbosity=2).run(suite)
assert len(result.failures)==1 and len(result.errors)==1, 'Expected bounded-count failure and missing-retry IndexError'
assert 'IndexError: list index out of range' in result.errors[0][1]
assert 'AssertionError: 1 != 4' in result.failures[0][1]
print('Confirmed: both regressions fail against the base executable.')
