// A band worker of play.mjs's pool on a worker_thread, as the play page's
// is a Worker (web/band-worker.js, web/band.js): posts "ready" once it has
// instantiated the module, then runs every spawn given to it. Its log goes
// straight to fd 2, as the main thread blocks in the module.
import { writeSync } from "node:fs";
import { parentPort, workerData } from "node:worker_threads";
import { bandWorker } from "../../web/band.js";

await bandWorker(workerData, () => parentPort.postMessage("ready"), (text) => writeSync(2, text));
