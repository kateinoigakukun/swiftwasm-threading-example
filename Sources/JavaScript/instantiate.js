import { WASI, File, OpenFile, ConsoleStdout, PreopenDirectory } from 'https://esm.run/@bjorn3/browser_wasi_shim';
import { SwiftRuntime } from "/static/JavaScriptKit_JavaScriptKit.resources/Runtime/index.mjs";

export async function instantiate({ module, addToImports, threadChannel }) {
  const args = ["main.wasm"]
  const env = []
  const fds = [
    new OpenFile(new File([])), // stdin
    ConsoleStdout.lineBuffered((stdout) => {
      console.log(stdout);
    }),
    ConsoleStdout.lineBuffered((stderr) => {
      console.error(stderr);
    }),
    new PreopenDirectory("/", new Map()),
  ];
  const wasi = new WASI(args, env, fds);

  const swiftRuntime = new SwiftRuntime({ sharedMemory: true, threadChannel });
  const importObject = {
    wasi_snapshot_preview1: wasi.wasiImport,
    javascript_kit: swiftRuntime.wasmImports,
  };
  addToImports(importObject);
  const instance = await WebAssembly.instantiate(module, importObject);
  console.log("Instance", instance);

  swiftRuntime.setInstance(instance);
  return { swiftRuntime, wasi, instance };
}
