// Opt-in instrumentation of the upstream Cardinal App, search hook and VirtualList.
// Imports reference the actual upstream checkout layout; see UPSTREAM.md.
import { invoke } from "../cardinal/node_modules/@tauri-apps/api/core";
import { listen } from "../cardinal/node_modules/@tauri-apps/api/event";
import { getCurrentWebviewWindow } from "../cardinal/node_modules/@tauri-apps/api/webviewWindow";

export async function startBenchmark() {
  const queries = ["EE.en", "everything-mac", "package.json", "a"];
  const samples: object[] = [];
  const typingSamples: object[] = [];
  let typingStep = -1;
  const drawIntervals: number[] = [];
  let iteration = -1;
  let submitted = 0;
  let backendMS = 0;
  let inputAt = 0;
  let currentQuery = "";
  let version: number | null = null;
  let pending = false;
  let finished = false;
  await getCurrentWebviewWindow().setFocus();
  await listen<number>("native_benchmark_backend", ({ payload }) => {
    backendMS = payload;
  });
  window.addEventListener("native-benchmark-submit", (event) => {
    const detail = (event as CustomEvent).detail;
    submitted = detail.startTs;
    currentQuery = detail.query;
    pending = true;
  });
  const save = (error?: string) => {
    if (finished) return;
    finished = true;
    void invoke("native_benchmark_report", {
      payload: JSON.stringify(
        { samples, typingSamples, scrollRAFIntervalsMS: drawIntervals, error },
        null,
        2,
      ),
    });
  };
  const scroll = () => {
    const viewport = document.querySelector(
      ".virtual-list",
    ) as HTMLElement | null;
    let ticks = 0;
    let previous = 0;
    const frame = (now: number) => {
      if (previous) drawIntervals.push(now - previous);
      previous = now;
      viewport?.dispatchEvent(
        new WheelEvent("wheel", {
          deltaY: 300,
          bubbles: true,
          cancelable: true,
        }),
      );
      if (++ticks < 180) requestAnimationFrame(frame);
      else save();
    };
    requestAnimationFrame(frame);
  };
  const next = () => {
    iteration++;
    if (iteration >= queries.length * 23) {
      if (typingStep < 0) typingStep = 0;
      if (typingStep >= 12) {
        scroll();
        return;
      }
      setTimeout(() => {
        const input = document.getElementById(
          "search-input",
        ) as HTMLInputElement;
        inputAt = performance.now();
        Object.getOwnPropertyDescriptor(
          HTMLInputElement.prototype,
          "value",
        )!.set!.call(input, typingStep % 2 === 0 ? "everything-mac" : "package.json");
        input.dispatchEvent(new Event("input", { bubbles: true }));
      }, 80);
      return;
    }
    setTimeout(() => {
      const input = document.getElementById("search-input") as HTMLInputElement;
      if (!input) {
        save("Search input unavailable");
        return;
      }
      input.focus();
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )!.set!.call(input, queries[Math.floor(iteration / 23)]);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      setTimeout(() => {
        inputAt = performance.now();
        input.dispatchEvent(
          new KeyboardEvent("keydown", {
            key: "Enter",
            code: "Enter",
            bubbles: true,
          }),
        );
      }, 10);
    }, 80);
  };
  window.addEventListener("native-benchmark-draw", (event) => {
    const detail = (event as CustomEvent).detail;
    if (!pending || detail.version === version || finished) return;
    version = detail.version;
    pending = false;
    const now = performance.now();
    if (typingStep >= 0) {
      if (typingStep >= 2)
        typingSamples.push({
          debounceMS: 300,
          sample: {
            query: currentQuery,
            rows: detail.count,
            backendMS,
            submissionToDrawMS: now - submitted,
            inputToDrawMS: now - inputAt,
          },
        });
      typingStep++;
      next();
      return;
    }
    if (iteration >= 0 && iteration % 23 >= 3)
      samples.push({
        query: currentQuery,
        rows: detail.count,
        backendMS,
        submissionToDrawMS: now - submitted,
        inputToDrawMS: now - inputAt,
      });
    next();
  });
  setTimeout(() => {
    if (iteration === -1 && !pending) next();
  }, 2500);
  setTimeout(() => {
    if (!finished) save("Timed out");
  }, 120000);
}
