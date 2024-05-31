import { instantiate } from "./instantiate.js"
import { WASIThreads } from "./wasi-threads.js"
import * as WasmImportsParser from 'https://esm.run/wasm-imports-parser/polyfill.js';

// TODO: Remove this polyfill once the browser supports the WebAssembly Type Reflection JS API
// https://chromestatus.com/feature/5725002447978496
globalThis.WebAssembly = WasmImportsParser.polyfill(globalThis.WebAssembly);

async function start() {
  const response = await fetch("/static/MyApp.wasm");
  const module = await WebAssembly.compileStreaming(response);
  const memoryImport = WebAssembly.Module.imports(module).find(i => i.module === "env" && i.name === "memory");
  if (!memoryImport) {
    throw new Error("Memory import not found");
  }
  if (!memoryImport.type) {
    throw new Error("Memory import type not found");
  }
  const memory = new WebAssembly.Memory(memoryImport.type);
  const wasiThreads = new WASIThreads({ module, memory });
  const { instance, swiftRuntime, wasi } = await instantiate({ module, wasiThreads });
  wasi.initialize(instance);

  swiftRuntime.main();
}

start();
