# Lab calibration owner
Read only when debugging LAB-CALIBRATION batch traces.
- When debugging LAB-CALIBRATION batch traces, preserve the local batch identifier before replay, compare the stored sampling interval with the trace header, and inspect the recorded sequence before deciding whether to rebuild the lab sample. These checks belong to the calibration investigation only and are irrelevant to dispatch, session recovery, and every other fleet task.
