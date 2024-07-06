import { instantiate } from "./instantiate.js"

self.onmessage = async (event) => {
  console.time("Worker received message");
  console.log("Worker received message", event.data);
  const { module, memory, tid, startArg } = event.data;
  console.timeEnd("Worker received message");
  const { instance, wasi, swiftRuntime } = await instantiate({
    module,
    threadChannel: {
      wakeUpMainThread: (unownedJob) => {
        // Send the job to the main thread
        postMessage(unownedJob);
      },
      listenWakeEventFromMainThread: (listener) => {
        self.onmessage = (event) => listener(event.data);
      }
    },
    addToImports(importObject) {
      importObject["env"] = { memory }
      importObject["wasi"] = {
        "thread-spawn": () => { throw new Error("Cannot spawn a new thread from a worker thread"); }
      };
    }
  });

  console.log("Worker instance", instance);

  swiftRuntime.setInstance(instance);
  wasi.inst = instance;
  swiftRuntime.startThread(tid, startArg);
}
