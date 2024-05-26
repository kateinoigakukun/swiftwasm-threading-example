import { instantiate } from "./instantiate.js"
import { WASIThreads } from "./wasi-threads.js"

async function start() {
  const response = await fetch("/static/MyApp.wasm");
  const module = await WebAssembly.compileStreaming(response);
  const metadata = await (await fetch("/static/wasm.meta.json")).json();
  const memory = new WebAssembly.Memory({ initial: metadata.memoryInitial, maximum: metadata.memoryMaximum, shared: true });
  const wasiThreads = new WASIThreads({ module, memory });
  const { instance, swiftRuntime, wasi } = await instantiate({ module, wasiThreads });
  wasi.initialize(instance);

  swiftRuntime.main();
}

start();
