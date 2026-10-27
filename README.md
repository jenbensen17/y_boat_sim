# RoboBoat Simulator

The BYU RoboBoat course in Gazebo, with a simulated BlueBoat running ArduPilot.
Built on [coug_gazebo](https://github.com/cougars-auv/coug_gazebo) from the BYU FROST Lab.

One command starts everything: the course, the boat, ArduPilot SITL, MAVROS,
QGroundControl forwarding, and two viewers you open in a browser.

## What you need

| Computer | Install |
|---|---|
| Windows | [Docker Desktop](https://www.docker.com/products/docker-desktop/) with WSL 2. Run the commands below in your WSL terminal |
| Mac | Docker Desktop |
| Linux | Docker Engine with the compose plugin |

QGroundControl and [Foxglove](https://foxglove.dev/download) are optional.

## Start it

```bash
git clone git@github.com:jenbensen17/y_boat_sim.git
cd y_boat_sim
docker compose up -d
```

The first start downloads the image (several GB). If it isn't published yet,
Docker builds it from this folder instead, which takes 30 to 60 minutes once.
After that, the sim is ready within a minute of starting it. The boat
spawns on the course, armed and in GUIDED mode, waiting for commands.

Stop it with `docker compose down`. Get the newest image with `docker compose pull`.

## Watch and control it

| What | How |
|---|---|
| QGroundControl | Open it; it connects by itself on UDP 14550 |
| ArduPilot terminal | `docker compose run --rm console` (try `status`, `mode HOLD`; Ctrl+D quits) |
| The sim in a browser | Open [localhost:8080](http://localhost:8080) |
| Foxglove | Open connection → Foxglove WebSocket → `ws://localhost:8765` |
| Gazebo window | `docker compose --profile gui up -d gui` (Windows with WSL, or Linux) |
| ROS 2 topics | From any container on the host network with `ROS_DOMAIN_ID=10` |
| Logs | `docker compose logs -f sim` |

The browser viewer takes about a minute to load the first time (it downloads
35 MB of models from the sim), then follows the boat live. Use the buttons to
follow the boat or move the camera freely.

The Gazebo window draws on the CPU, so it can be slow. It runs separately from the
sim, so it never slows the sim down. Close it with `docker compose --profile gui down gui`.
On Linux, run `xhost +local:` once per login before opening it.

## Drive it from y_boat_core

Start the sim, then y_boat_core's dev container. They share `ROS_DOMAIN_ID=10`
and the host network, so they see each other's topics. Run `cmd_vel_bridge` and
publish `/cmd_vel`, or send body-frame velocity yourself on
`/mavros/setpoint_raw/local` (frame 8, type_mask 1479).

## What it publishes

| Topic | What |
|---|---|
| `/clock` | Sim time |
| `/yboat1gz/odometry/truth` | The boat's true pose (frame `map`, child `yboat1gz/base_link`) |
| `/yboat1gz/gps/fix` | Simulated GPS |
| `/mavros/...` | Everything MAVROS provides, including `/mavros/state` |

The truth odometry is the real position, with no noise. It stands in for
perception's estimate until that exists.

## Camera and LiDAR

Off by default. Without a GPU they render on the CPU, and because Gazebo and
ArduPilot run in lockstep, that slows the whole sim to a crawl. GPS and IMU still
work. On a machine with a GPU:

```bash
docker compose run --rm sim ros2 launch /sim/launch/sim.launch.py sensors:=true
```

## Sim-only settings

The boat starts armed and cannot be disarmed (`ARMING_REQUIRE 0`), and a script
switches it to GUIDED at startup. Any velocity command moves it straight away.
Never copy these settings to the real boat.

## How it fits together

| File | What |
|---|---|
| `Dockerfile` | Builds ArduPilot Rover-4.7.1 and the Gazebo packages into one image |
| `sim.repos` | The upstream packages, each pinned to a commit |
| `launch/sim.launch.py` | Starts the world, the boat, the QGC forwarder, MAVROS and the viewers |
| `config/` | Settings coug_gazebo's launch files read, and the web viewer's config |
| `web/` | The browser viewer page, built on gzweb (the library behind app.gazebosim.org) |
| `setup.bash`, `entrypoint.sh` | The environment every command in the image runs with |
| `compose.yaml` | The `sim`, `ports`, `console` and `gui` services |
| `.github/workflows/image.yml` | Publishes the image for Intel/AMD and Apple Silicon |

ArduPilot's MAVLink ports: 5760 goes to QGroundControl, 5762 to the ArduPilot
terminal, 5763 to MAVROS.

The viewers listen on ports 18080, 18765 and 19090 inside the sim. Docker
Desktop keeps host-network ports inside its VM, so the small `ports` service
forwards them to 8080, 8765 and 9090 on your computer.

Why our own viewer page instead of app.gazebosim.org/visualization: that site
can't load this sim. Gazebo Harmonic's websocket server leaves two definitions
out of what it sends, and the server stops sending poses on a connection that
has just downloaded a lot of models. `web/main.js` works around both. Browsers
also block public websites from reaching `localhost`, which a local page avoids.

## When something's wrong

- **QGroundControl shows nothing:** check `docker compose logs sim` for errors,
  and that nothing else on your computer is using UDP 14550.
- **The browser viewer won't connect:** check `docker compose ps` shows `ports`
  running, and wait for the sim to finish starting (about a minute).
- **The sim runs slowly:** run `docker compose exec sim gz stats`. A real-time
  factor well under 1 means something is rendering on the CPU; make sure
  `sensors` is off.
