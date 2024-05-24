import { instantiate } from "./instantiate.js"
import { WASIThreads } from "./wasi-threads.js"

async function start() {
  const response = await fetch("/static/MyApp.wasm");
  const module = await WebAssembly.compileStreaming(response);
  const wasiThreads = new WASIThreads({ module });
  const { instance, swiftRuntime, wasi } = await instantiate({ module, wasiThreads });
  wasi.initialize(instance);

  swiftRuntime.main();
}

start();
