# Documentation

## Guides (start here)

| Guide | What it covers |
|---|---|
| [ros2-development.md](ros2-development.md) | Topics & services, the four rules that matter for Nav2, a minimal control node, and the three ways to give waypoint missions. |
| [y_boat_core-integration.md](y_boat_core-integration.md) | Running the autonomy stack against the sim over DDS, and what sim-to-real parity buys us. |
| [platforms.md](platforms.md) | Prerequisites per OS, plus WSL2, macOS and headless/CI notes. |
| [troubleshooting.md](troubleshooting.md) | Log locations and the common failure modes. |

## Build history (reference only)

These record how the sim was built and what was measured at each step. They are
**not** maintained as user documentation — read them for background and rationale,
not for current instructions.

| Document | Step |
|---|---|
| [step1a_report.md](step1a_report.md) | Gazebo GUI on the GPU + standalone ArduPilot SITL. |
| [step1b_report.md](step1b_report.md) | BlueBoat floating in Gazebo, driven by SITL through the ArduPilot Gazebo plugin. |
| [step1c3_report.md](step1c3_report.md) | Pinned versions, `ros_gz_bridge`, MAVROS control. The sim as it stands today. |
| [SETUP_LOG.md](SETUP_LOG.md) | Raw chronological log of every attempt, including the dead ends. |

`drive_test.py` and `ros_control_test.py` are the throwaway harnesses used to produce
the measurements in the step 1b and 1c reports. They are kept because those reports
cite them. **The maintained test is [`tests/test_boat_drive.py`](../tests/test_boat_drive.py),
run via `./test_ros.sh`.**
