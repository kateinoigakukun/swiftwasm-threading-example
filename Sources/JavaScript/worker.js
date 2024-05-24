import { instantiate } from "./instantiate.js"
import { WASIThreads } from "./wasi-threads.js"

self.onmessage = async (event) => {
  console.log(event.data);
  const { module, memory, tid, startArg } = event.data;
  const wasiThreads = new WASIThreads({ module, memory });
  const { instance, wasi } = await instantiate({ module, wasiThreads });
  wasi.inst = instance;

  instance.exports.wasi_thread_start(tid, startArg);
}
