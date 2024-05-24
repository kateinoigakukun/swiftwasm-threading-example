export class WASIThreads {
    constructor(options) {
        const { module } = options;
        if (typeof options.memory === "undefined") {
            const memoryImport = WebAssembly.Module.imports(module).find((i) => i.module === "env" && i.name === "memory");
            if (!memoryImport) {
                throw new Error("No memory import (env.memory) found in the module");
            }
            this.memory = new WebAssembly.Memory(memoryImport.type);
        } else {
            // In child threads, the memory is passed in as an option
            this.memory = options.memory;
        }
        this.module = module;
        this.tidSymbol = Symbol("tid");
        this.nextTid = 1;
    }

    addToImports(imports) {
        const env = imports.env || {};
        env["memory"] = this.memory;
        imports.env = env;

        const wasi = imports.wasi || {};
        wasi["thread-spawn"] = this.spawn.bind(this);
        imports.wasi = wasi;
    }

    spawn(startArg) {
        const worker = new Worker("Sources/JavaScript/worker.js", { type: "module" })
        const tid = this.nextTid;
        this.nextTid += 1;
        Object.defineProperty(worker, this.tidSymbol, { value: tid });
        worker.postMessage({ module: this.module, memory: this.memory, tid, startArg })
        return tid;
    }
}
