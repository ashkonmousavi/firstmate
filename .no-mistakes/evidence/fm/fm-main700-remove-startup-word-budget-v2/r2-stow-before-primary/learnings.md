# Learnings
<!-- memory tiers: see the stow skill -->
- Fleet-wide dispatch must resolve the registered home before selecting its transport. <!--a:2026-10-06-->
- Fleet-wide dispatch must resolve the registered home before selecting its transport. <!--a:2026-10-06-->
- Completed lab release 0.0.1 used the superseded path /disposable/obsolete. <!--a:2026-01-01-->
- Temporary compatibility workaround for closed lab ticket LAB-OLD was retired when that ticket closed. <!--p:2026-01-01-->
- When debugging LAB-CALIBRATION batch traces, preserve the local batch identifier before replay, compare the stored sampling interval with the trace header, and inspect the recorded sequence before deciding whether to rebuild the lab sample. These checks belong to the calibration investigation only and are irrelevant to dispatch, session recovery, and every other fleet task. <!--a:2026-10-06-->
