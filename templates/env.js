// Functions exported here are callable from D as `env` imports.
//
// D:
//   extern(C) int js_add(int a, int b);
//   export extern(C) void main() { js_add(1, 2); }
//
// JavaScript:
//   export function js_add(a, b) { return a + b; }
//
// To use your own file, put an ES module named `env.js` next to the served
// wasm, or copy it there from your recipe (for example with `copyFiles`).
