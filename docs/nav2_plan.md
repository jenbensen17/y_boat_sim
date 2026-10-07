# Getting Nav2 to drive the BlueBoat — plan and background

Written after Steps 1a–2, which got the simulator running and `y_boat_core` talking to it.
This is the roadmap from "we can drive the boat from ROS 2" to "Nav2 navigates it around
obstacles", plus the background needed to understand why the steps are in this order.

**This is one of two tracks.** The perception team has its own backlog, and the obstacle
avoidance that makes Nav2 worth having sits exactly on the seam between the two. The plan
below is therefore written so the nav track never waits on the perception track: the two
sides agree an interface early, each develops against its own side of it, and they meet at
a scheduled integration. Section 4 is the cross-team part — read it before Phase 3, not
during.

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
| 3 | **Sensor data** (`LaserScan` / `PointCloud2`) | Populates the costmaps | **MISSING** — and cross-team (§4) |
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

**Start the perception conversation during this phase, in parallel.** It needs nothing
from Phase 0's code and has the longest lead time of anything in the plan — see section 4
for what to ask and what to propose.

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

### Phase 3 — Perception integration (cross-team)

This is where the two tracks meet, so it splits into halves that run **in parallel** and
join at the end. Do not treat it as one serial block of work.

**3a — Make the sim the perception team's test bench (nav/sim side).**

1. Add sensor models to the BlueBoat SDF — LiDAR and/or camera — at the mount pose the
   real boat will use, and bridge them through `ros_gz_bridge` onto **the topic names and
   `frame_id`s from the architecture diagram** (`camera_1/image_raw`, and whichever of
   `lidar/lidar_raw` / `/lidar/points` survives §4). Sim topics that differ from the real
   drivers' mean every perception node gets rewritten at integration time.
2. Add RoboBoat course props to the world: buoys (red / green / yellow), gates, a dock.
3. Publish TF for every sensor frame from the boat description, so `base_link -> lidar_link`
   comes from the same file that places the sensor.
4. Record bags of representative runs. Perception can then iterate offline, without Gazebo
   and without a GPU — this is the single highest-leverage thing the sim can give them.

**3b — The obstacle path into Nav2 (nav side, against a stub).**

Enable the costmap obstacle layer against a **stub obstacle publisher** that emits the
agreed message from Gazebo ground truth. Nav2 avoidance can be built, tuned and
demonstrated end to end before perception's first real detection exists. When the real node
lands, swapping it in should be a launch-file change — that's the test of whether the
contract in section 4 was specified well enough.

**Perception team's half (theirs).** Detection and classification on the topics 3a
provides, publishing the agreed obstacle and detection topics.
`boat_perception/lidar_processor` in `y_boat_core` is currently an empty node with no input;
3a gives it one.

**Milestone (nav):** the boat routes around a stub-published obstacle that is not in any map.
**Milestone (joint):** the same run, driven by the perception team's node instead of the stub.

This is the first capability that ArduPilot AUTO genuinely cannot provide.

### Phase 4 — RoboBoat course elements (cross-team)

Buoys, gates, docks. Competition-specific behaviours on top of a working nav stack, and the
first phase where nav genuinely needs *semantics* (which buoy is red) and not just geometry
(something is there). Expect the task logic itself to be a shared or third-party
responsibility — worth deciding who owns it before Phase 3 finishes, not after.

---

## 4. Working with the perception team

Perception is a separate team with its own backlog. Everything in this section exists to
make that a non-issue rather than a dependency.

### Start from the architecture diagram — it already names the topics

`RoboBoat Perception.drawio` (team original, also copied to `sim_scratch/docs/`) and
`RoboBoat_Architecture_v2.drawio` already lay out the perception pipeline and its topic
names. **Do not invent a parallel naming scheme.** What the diagram settles, and what it
leaves open, are different things:

| Topic (from the diagram) | Producer → consumer | Settled? |
|---|---|---|
| `camera_1/image_raw` | camera driver → object detection/classification | name only |
| `lidar/lidar_raw` (v1) / `/lidar/points` (v2) | LiDAR driver → LiDAR processor | **name conflicts between v1 and v2** |
| `camera_1/objects` | detection/classification → object tracking | name only |
| `lidar/clusters` | LiDAR processor → object tracking | name only |
| `lidar/occupancy` | LiDAR processor → geometry map | name only; see the collision below |
| `map/objects` | object tracking → world model | name only; **needs TF from nav Phase 0** |
| `map/geometry` | geometry map → world model | name only |
| `/task_status` | world model → mission task node | name only |

The diagram gives **names and direction**. For every one of those rows it is silent on the
four things that actually make two nodes interoperate: **message type, `frame_id`,
publish rate, and QoS.** Filling those in is the cheap, concrete ask — an interface
control doc, which `RoboBoat_Architecture_v2.drawio` already lists under "open decisions"
as "topic names: finalize in the interface control doc".

The split worth preserving while doing that: **geometry for avoidance, semantics for
tasks.** Nav2 needs only an obstacle input to avoid things. Buoy colours and gate identity
flow through `map/objects` → world model → mission task node, which is Phase 4 and should
not block Phase 3.

### The one architectural collision to resolve

v1 has the LiDAR processor producing `lidar/occupancy` and a "Geometry map" node — i.e.
**perception building its own occupancy grid.** That is the same job `nav2_costmap_2d`
does, and Nav2's obstacle layer does not consume a pre-baked occupancy grid; it consumes
`LaserScan` / `PointCloud2` and maintains the grid itself. v2 already resolves this by
routing LiDAR points straight into the costmap obstacle layer.

**Two grids maintained by two teams from the same sensor is the single most expensive
mistake available here** — they will disagree, and no one will be able to say which one
the boat believed. Get explicit agreement on one of:

- perception publishes clustered obstacle points, Nav2 owns the only grid (**recommended**,
  and what v2 shows); or
- perception owns the grid and Nav2 consumes it as a static/`nav2_costmap_2d` map layer,
  in which case the obstacle layer is off and perception inherits Nav2's timing and frame
  requirements.

### The dependency runs both ways

`map/objects` and `map/geometry` are, by their names, **in the `map` frame**. Nothing can
publish in the `map` frame until `map -> odom -> base_link` exists — which is Phase 0 of
this plan, and does not exist yet. So the perception team's world model is blocked on nav's
Phase 0 just as nav's Phase 3 is blocked on their detections.

That is worth saying to them explicitly: **Phase 0 is not just nav plumbing, it is their
unblocker too.** It also means neither team should wait — they can develop detection in
sensor frames against bags long before the TF tree exists.

### Why ask for a point cloud even when the sensor is a camera

`nav2_costmap_2d`'s obstacle and voxel layers consume `LaserScan` and `PointCloud2` and
nothing else. `lidar/clusters` is already the right shape for this if it is typed as a
`PointCloud2` of cluster points — that one decision makes the whole obstacle path work with
stock Nav2 and no custom plugin.

`camera_1/objects`, by contrast, will be a list of buoy poses, and *someone* has to convert
that into occupied space. That someone should be the side that knows each detection's
uncertainty and false-positive rate, i.e. perception — the alternative is a custom costmap
plugin on the nav side that re-derives what perception already knew and threw away.

Publishing empty clouds matters too: a costmap layer that stops receiving data does not
clear old obstacles, so the boat will dodge a buoy that is no longer there.

### Ownership — a proposal to settle, not a decision

| Item | Proposed owner | Why |
|---|---|---|
| Gazebo sensor models and mount poses | sim (you) | The same description publishes the TF. Split them and a sensor pose can disagree with its transform — invisible, and it poisons every downstream result. |
| Course props / world files | sim (you), to perception's asset spec (buoy sizes, colours, materials) | One world everybody tests against |
| `ros_gz_bridge` config | sim (you) | It's the sim's boundary |
| Detection / classification nodes | perception | Their expertise, their iteration loop |
| Message definitions | shared package (`y_boat_msgs`), reviewed by both | Neither side can break the other silently |
| Nav2 + costmap config | you | |
| Stub obstacle publisher | you | It's your unblocker, not theirs |
| Bag recordings from the sim | you produce, they consume | Lets them work without Gazebo |
| The interface control doc (types/frames/rates/QoS per topic) | joint, but *somebody* has to hold the pen | It is already listed as an open decision on the v2 diagram; unowned open decisions stay open |
| World model / mission task node | per the v2 legend, "systems team" | Confirm that's still true — it sits between perception's output and Nav2's goals, so an unowned box there stalls both |

Sensor models sitting with the sim owner is the one line worth arguing for: it keeps
geometry and TF in a single file. Everything else is negotiable.

### Cross-team gotchas that will actually bite

These are the failure modes of two teams' nodes meeting for the first time, and all of them
fail *silently*:

1. **`use_sim_time`.** Every node on both sides must set it `true` against Gazebo. A
   perception node running on wall clock stamps its output at a time the costmap considers
   ancient, so the data is dropped with at most a "transform timeout" warning.
2. **QoS.** Sensor topics want best-effort sensor QoS. A reliable subscriber on a
   best-effort publisher receives *nothing at all*, with no error on either side.
3. **Optical frames.** Camera optical frames are z-forward / x-right (REP-103); body frames
   are x-forward / z-up. Agree explicitly which frame detections are stamped in, and make
   sure the `_optical_frame` link exists in TF.
4. **`ROS_DOMAIN_ID`.** `run_sim.sh` defaults to `10`. A perception container on the default
   `0` sees an empty graph and looks exactly like a crashed publisher.
5. **Exact `frame_id` spellings.** Write them down now: `map`, `odom`, `base_link`,
   `lidar_link`, `camera_link`, `camera_optical_frame`. A typo here surfaces as "TF tree
   disconnected" days later.

### Decisions the diagram leaves open

Get these on the table in one meeting, and block nothing on the answers:

- **Message type, frame, rate and QoS for every topic in the table above.** This is the
  interface control doc the v2 diagram already asks for.
- **One occupancy grid or two** — the `lidar/occupancy` / Nav2 costmap collision above.
  Highest-consequence item on this list.
- **`lidar/lidar_raw` or `/lidar/points`** — v1 and v2 disagree; pick one and fix the
  diagrams, including whether topics are leading-slash absolute or namespaced.
- **LiDAR, camera, or both on the *obstacle* path** (semantics can come from the other one).
- **Who owns the Gazebo sensor models and course props** — proposal above.
- **Real sensor part numbers and mount poses.** The sim cannot be faithful without them,
  and a wrong mount height changes what the sensor can see of a low buoy. The v2 diagram
  still lists the LiDAR and camera generically.
- **Where shared message definitions live** and who reviews changes to them.
- **Jetson model → ROS distro** (Nano/Humble vs Orin/Jazzy, per v2's open decisions). It is
  a perception constraint as much as a nav one — it caps the detector they can run, and
  the sim is currently Jazzy-only.

### If the perception track slips

Phases 0–2 and 3b-with-a-stub are unaffected — that is the point of the stub. For
competition fallback, ArduPilot AUTO already handles the "visit these GPS points" tasks
with no perception at all; the tasks that need obstacle avoidance are the ones at risk, and
they are the ones worth flagging early to the team lead.

### Integration cadence

One joint run in the sim on a regular cadence beats a single big integration at the end.
Cheapest version: a scripted sim scenario both sides run before merging — boat, course
props, perception node, Nav2 — with a pass condition ("boat clears the buoy field without
contact"). It doubles as the regression test when either side changes.

---

## 5. Boat-specific gotchas

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

## 6. Expectation setting

Phases 0–2 add **no new capability**. They are infrastructure and tuning. The first
genuinely new behaviour appears in Phase 3, with obstacle avoidance.

Worth telling the team up front, so a few weeks of necessary groundwork doesn't read as no
progress.

Say the cross-team shape out loud too, for the same reason: the demo everyone is waiting
for — boat dodges a buoy — needs both tracks to land, and the nav side will reach its half
of it (dodging a *stub* obstacle) well before perception reaches theirs. That is the plan
working, not either team being behind. The two things that genuinely put the joint
milestone at risk are an interface agreed late and sim sensors that don't match the real
mount — both cheap to fix now and expensive to fix at integration.

---

## 7. Suggested order of learning

1. **TF** — Nav2 docs, "Setting Up Transformations". The `map`/`odom` split above.
2. **Nav2 Getting Started** — run their TurtleBot example to see a working stack before
   adapting one.
3. **Nav2 configuration** — behaviour tree, planner/controller servers, costmap layers.
   Mostly YAML; the concepts matter more than the syntax.
4. **Costmaps** — how sensor data becomes an obstacle grid, and what the obstacle layer
   will and won't accept as input. This is what lets you write the perception contract in
   section 4 from knowledge rather than guesswork, so read it *before* that conversation,
   not in Phase 3.

Official docs: `docs.nav2.org`

---

## 8. Known blockers carried over

Outstanding from earlier steps, independent of Nav2:

- **The team image with MAVROS is not published.** A teammate cloning `y_boat_core` today
  gets `DOCKER_IMAGE=latest`, which has no MAVROS, and `boat_control` silently falls back to
  world-frame control. This blocks everyone but the machine it was built on.
- **`dockerfile.nano` has no MAVROS** — ROS Humble, needs `ros-humble-mavros`. The Jetson
  cannot run `boat_control` at all yet.
- **Body-frame control is not conclusively verified.** The drive test moved almost purely
  +Y, consistent with both body-frame and world-frame control. One run from a rotated
  heading settles it — worth doing before building Nav2 on the assumption.
- **The perception interface is half-defined.** The architecture diagrams name the topics
  and their direction, but no topic has a message type, frame, rate or QoS, `lidar/lidar_raw`
  and `/lidar/points` conflict between v1 and v2, and v1 has perception building an occupancy
  grid that duplicates Nav2's costmap (§4). Not a nav blocker until Phase 3 — the stub covers
  it — but it has the longest lead time on this list, because settling it needs another
  team's attention and their real sensor choice. Raise it during Phase 0, when it costs a
  conversation; raised during Phase 3 it costs a rewrite.
