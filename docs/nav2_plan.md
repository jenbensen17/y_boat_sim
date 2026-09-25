# Getting Nav2 to drive the BlueBoat — plan and background

Written after Steps 1a–2, which got the simulator running and `y_boat_core` talking to it.
This is the roadmap from "we can drive the boat from ROS 2" to "Nav2 navigates it around
obstacles", plus the background needed to understand why the steps are in this order.

---

## 1. The mental model

The most common misconception is that Nav2 replaces the autopilot. It does not. ArduPilot
stays in charge of thrusters, heading hold and stabilisation. Nav2 sits *above* it and
treats ArduPilot as a **velocity servo**:

```
Nav2                    "go to that point, route around obstacles"
  |   geometry_msgs/Twist on /cmd_vel      (forward m/s, yaw rad/s)
  v
cmd_vel bridge node     translate ROS velocity -> MAVLink setpoints
  |   mavros_msgs/PositionTarget, FRAME_BODY_NED, streamed at 10 Hz
  v
MAVROS -> MAVLink -> ArduPilot   (stays in GUIDED the entire time)
  |   thruster mixing, heading hold, low-level control
  v
BlueBoat thrusters in Gazebo
```

Two consequences worth internalising:

- **The boat sits in GUIDED permanently** while Nav2 drives. You do *not* use ArduPilot
  AUTO missions at the same time. AUTO and Nav2 are two alternative ways to do autonomy;
  picking Nav2 means ArduPilot stops doing route planning and just executes velocities.
- **ArduPilot still owns safety and stabilisation.** Arming checks, failsafes and thruster
  mixing are unchanged. Nav2 only ever asks for velocities.

### Why bother, when ArduPilot AUTO already does waypoints?

Be clear-eyed about this: ArduPilot AUTO already flies waypoint missions, and it does it
well. Nav2's value is **dynamic replanning around obstacles it discovers at runtime** —
which is what RoboBoat buoys, gates and other vessels require. If a task only needs
"visit these GPS points", AUTO is simpler and already works.

That also tells you where the real work is: the obstacle sensing, not Nav2 itself.

---

## 2. What Nav2 requires before it will even start

Nav2 is strict about four contracts. Current status for this project:

| # | Contract | What it is | Status |
|---|---|---|---|
| 1 | **TF: `map -> odom -> base_link`** | Nav2 constantly asks "where is `base_link` in the `map` frame?" | **MISSING** — hard blocker |
| 2 | **Odometry** (`nav_msgs/Odometry`) | Velocity feedback for the local controller | Present but only ~3.7 Hz |
| 3 | **Sensor data** (`LaserScan` / `PointCloud2`) | Populates the costmaps | **MISSING** |
| 4 | **A consumer for `/cmd_vel`** | Nav2 publishes velocities and assumes a robot base listens | **MISSING** |

MAVROS publishes only *static* ENU/NED alias transforms (`map -> map_ned`,
`odom -> odom_ned`, `base_link -> base_link_frd`). There is no dynamic transform saying
where the boat actually is, so contract 1 is unmet and Nav2 will not run.

### The TF concept worth understanding first

`map -> odom -> base_link` is split into two transforms on purpose, and understanding why
makes the TF node obvious to write:

- **`odom -> base_link`** is *smooth but drifts*. It comes from dead reckoning / local
  estimation. It never jumps, so controllers can differentiate it safely — but over time it
  wanders away from truth.
- **`map -> odom`** is *accurate but jumps*. It's the correction applied when a global fix
  (GPS, or a localisation algorithm) says "you're actually over here". Jumps are fine here
  because nothing differentiates this transform.

Nav2's local controller relies on the smooth one; the global planner relies on the accurate
one. If you publish a single jumpy `map -> base_link`, the local controller misbehaves.

Read the Nav2 docs' "Setting Up Transformations" page before writing any TF code.

---

## 3. The plan

### Phase 0 — Foundation (the actual blocker)

Build the three missing pieces of plumbing. No Nav2 yet.

1. **TF publisher node.** Subscribe `/mavros/local_position/odom`, broadcast
   `odom -> base_link`. Publish `map -> odom` as identity to begin with (GPS is already the
   position source, so there is no separate localisation correction yet).
2. **`cmd_vel` bridge node.** Subscribe `/cmd_vel` (`geometry_msgs/Twist`), publish
   `/mavros/setpoint_raw/local` (`mavros_msgs/PositionTarget`) with:
   - `coordinate_frame: 8` (`FRAME_BODY_NED`)
   - `type_mask: 1479` (ignore position + acceleration + yaw; keep velocity and yaw_rate)
   - `velocity.x` = `twist.linear.x`, `yaw_rate` = `twist.angular.z`
   - **Published at 10 Hz continuously**, including zero-velocity messages when Nav2 is
     idle. ArduPilot has a **hardcoded 3 second** guided-setpoint timeout
     (`Rover/mode_guided.cpp`, `(millis() - _des_att_time_ms) > 3000`) — it is not a
     parameter. Stop publishing and the boat stalls every 3 seconds.
3. **Raise MAVROS stream rates** to ~20 Hz via `SRx_POSITION` or
   `/mavros/set_message_interval`. 3.7 Hz will make Nav2's controller loop unstable.

**Milestone:** `teleop_twist_keyboard` drives the boat, and RViz shows a connected TF tree.

This is the genuine unlock. Once done, the boat speaks standard ROS 2 and *any* ROS
navigation tool can drive it — not just Nav2.

**Why body frame matters here:** `/mavros/setpoint_velocity/cmd_vel_unstamped` looks like
the obvious topic to use, but MAVROS interprets it in the **world ENU frame** — the boat
would drive in a fixed compass direction regardless of heading. Nav2's `cmd_vel` is
body-frame by definition, so the bridge must use `setpoint_raw/local` with
`FRAME_BODY_NED`. This was verified in Step 1c.

### Phase 1 — Nav2 plumbing

Bring Nav2 up with an **empty costmap** — no sensors yet. Send a goal from RViz and watch
the boat drive to it.

**Milestone:** goal in RViz -> boat moves -> goal reached.

Do this before adding perception. With few moving parts, when something breaks the cause is
findable. This is where you actually learn how Nav2 is wired together: behaviour tree,
planner server, controller server, costmap layers.

### Phase 2 — Tuning

Step 1b measured cross-track error averaging **12.6 m on 25 m legs**, with the boat
overshooting corners. Nav2's controller will fight that, and you will not be able to tell
whether bad tracking is Nav2's fault or the vehicle's.

Candidates: `WP_RADIUS`, `CRUISE_SPEED` / `WP_SPEED` (currently 2.0 m/s), turn-rate limits,
skid-steer steering gains.

**Milestone:** the boat tracks a straight line between waypoints within a boat length or two.

### Phase 3 — Perception

Add a LiDAR to the BlueBoat model in Gazebo, bridge it to `/scan` through `ros_gz_bridge`,
and feed it to the Nav2 costmap. `boat_perception/lidar_processor` in `y_boat_core`
currently has no input — this gives it one.

**Milestone:** the boat routes around an obstacle that is not in any map.

This is the first capability that ArduPilot AUTO genuinely cannot provide.

### Phase 4 — RoboBoat course elements

Buoys, gates, docks. Competition-specific behaviours on top of a working nav stack.

---

## 4. Boat-specific gotchas

Nav2 was designed for wheeled ground robots. Expect friction:

- **Boats cannot brake.** Momentum carries you past goals. Widen goal tolerances; expect
  overshoot the tutorials never mention.
- **Rotate-in-place is unreliable.** Several Nav2 recovery behaviours assume the robot can
  spin on the spot. A skid-steer boat approximates it badly in water. Plan to disable or
  replace some recoveries.
- **No reverse assumptions.** Check whether your chosen controller plugin assumes the robot
  can reverse freely.
- **Drift.** Wind and current push the boat off track with no control input at all. Waves
  are currently disabled in the sim world (`blueboat_waves.sdf`), which makes early work
  easier — turn them back on before trusting any result.

---

## 5. Expectation setting

Phases 0–2 add **no new capability**. They are infrastructure and tuning. The first
genuinely new behaviour appears in Phase 3, with obstacle avoidance.

Worth telling the team up front, so a few weeks of necessary groundwork doesn't read as no
progress.

---

## 6. Suggested order of learning

1. **TF** — Nav2 docs, "Setting Up Transformations". The `map`/`odom` split above.
2. **Nav2 Getting Started** — run their TurtleBot example to see a working stack before
   adapting one.
3. **Nav2 configuration** — behaviour tree, planner/controller servers, costmap layers.
   Mostly YAML; the concepts matter more than the syntax.
4. **Costmaps** — how sensor data becomes an obstacle grid. Relevant in Phase 3.

Official docs: `docs.nav2.org`

---

## 7. Known blockers carried over

Outstanding from earlier steps, independent of Nav2:

- **The team image with MAVROS is not published.** A teammate cloning `y_boat_core` today
  gets `DOCKER_IMAGE=latest`, which has no MAVROS, and `boat_control` silently falls back to
  world-frame control. This blocks everyone but the machine it was built on.
- **`dockerfile.nano` has no MAVROS** — ROS Humble, needs `ros-humble-mavros`. The Jetson
  cannot run `boat_control` at all yet.
- **Body-frame control is not conclusively verified.** The drive test moved almost purely
  +Y, consistent with both body-frame and world-frame control. One run from a rotated
  heading settles it — worth doing before building Nav2 on the assumption.
