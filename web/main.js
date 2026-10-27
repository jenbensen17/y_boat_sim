// Shows the running sim in the browser. Connects to the sim's Gazebo websocket
// on port 9090 of whichever computer served this page.
import { SceneManager } from 'gzweb';

const BOAT = 'yboat1gz';
const url = new URLSearchParams(location.search).get('ws')
  ?? `ws://${location.hostname}:9090`;

// Gazebo Harmonic's websocket server sends its message definitions without two
// enums they use, and gzweb then fails to read them and never connects (this is
// also why app.gazebosim.org/visualization doesn't work with this sim). The
// definitions are the first message on the socket, so add the enums to it.
// Copied from gz-msgs 10's image.proto and spherical_coordinates.proto.
const MISSING_ENUMS = `
enum PixelFormatType {
  UNKNOWN_PIXEL_FORMAT = 0; L_INT8 = 1; L_INT16 = 2; RGB_INT8 = 3; RGBA_INT8 = 4;
  BGRA_INT8 = 5; RGB_INT16 = 6; RGB_INT32 = 7; BGR_INT8 = 8; BGR_INT16 = 9;
  BGR_INT32 = 10; R_FLOAT16 = 11; RGB_FLOAT16 = 12; R_FLOAT32 = 13; RGB_FLOAT32 = 14;
  BAYER_RGGB8 = 15; BAYER_BGGR8 = 16; BAYER_GBRG8 = 17; BAYER_GRBG8 = 18;
}
enum SphericalCoordinatesType {
  SPHERICAL = 0; ECEF = 1; GLOBAL = 2; LOCAL = 3; LOCAL2 = 4;
}
`;

class PatchedWebSocket extends WebSocket {
  set onmessage(handler) {
    let first = true;
    super.onmessage = async (event) => {
      if (first) {
        first = false;
        const text = await event.data.text();
        if (text.includes('package gz.msgs;') && !text.includes('enum PixelFormatType')) {
          handler({ data: new Blob([text + MISSING_ENUMS]) });
          return;
        }
      }
      handler(event);
    };
  }

  get onmessage() {
    return super.onmessage;
  }
}
const NativeWebSocket = window.WebSocket;
window.WebSocket = PatchedWebSocket;

// Gazebo's websocket server stops sending poses on gzweb's connection after
// streaming it the scene's meshes (about 35 MB at startup), so the boat never
// moves. A second connection that only asks for poses keeps working, so take
// the poses from that and apply them the way gzweb does.
let posesStarted = false;
function streamPoses() {
  const root = scene.transport.root;
  const ws = new NativeWebSocket(url);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => ws.send(`sub,/world/${scene.transport.getWorld()}/dynamic_pose/info,,`);
  ws.onmessage = (event) => {
    // Frame: operation,topic,type,payload. The payload starts after the third comma.
    const bytes = new Uint8Array(event.data);
    let commas = 0;
    let start = 0;
    while (commas < 3 && start < bytes.length) {
      if (bytes[start++] === 44) commas++;
    }
    const type = new TextDecoder().decode(bytes.subarray(0, start - 1)).split(',')[2];
    const msg = root.lookupType(type).decode(bytes.subarray(start));
    for (const pose of msg.pose) {
      const entity = scene.scene.getByName(pose.name);
      if (entity) scene.scene.setPose(entity, pose.position, pose.orientation);
    }
  };
  ws.onclose = () => setTimeout(streamPoses, 2000);
}

const status = document.getElementById('status');
status.textContent = `Connecting to ${url}…`;

const scene = new SceneManager({ elementId: 'gz-scene', websocketUrl: url });
window.sim = scene; // for poking at the scene from the browser console

scene.getConnectionStatusAsObservable().subscribe((ready) => {
  status.textContent = ready ? 'Connected' : `Not connected to ${url}. Is the sim running?`;
  status.dataset.ready = ready;
  if (ready) {
    // Wait for the boat's model to arrive before pointing the camera at it
    setTimeout(() => scene.follow(BOAT), 3000);
    if (!posesStarted) {
      posesStarted = true;
      streamPoses();
    }
  }
});

// In Gazebo a wave shader draws the water. The browser can't run it, so the
// water plane comes out flat white and covers the lake. The park model has its
// own lake surface underneath, so hide the water plane and show that instead.
const hideWater = setInterval(() => {
  const water = scene.scene?.scene.getObjectByName('Coast Waves');
  if (water) {
    water.visible = false;
    clearInterval(hideWater);
  }
}, 1000);

document.getElementById('follow').onclick = () => scene.follow(BOAT);
document.getElementById('behind').onclick = () => scene.thirdPersonFollow(BOAT);
document.getElementById('free').onclick = () => scene.follow('');
window.addEventListener('resize', () => scene.resize());
