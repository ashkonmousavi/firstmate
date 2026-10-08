# Herdr presentation test cleanup
The live scenario assertions and named-session teardown passed.
The remaining private fixture tree could not be removed because spawn-owned state/anchor.git-hooks was mode 0500.
The test's cleanup_all uses plain rm -rf, while tests/lib.sh fm_test_remove_tree first restores owner permissions on fixture directories.
The affected cleanup occurrence in this test is cleanup_all's final rm -rf of TMP_ROOT.
The other rm calls remove writable test controls and are not implicated.
The intended repair restores owner permissions only on directories beneath this test's private TMP_ROOT before removing it.
No runtime source, fleet state, claim timestamp mechanism, or production credential is changed.
