// Talks to the Orchard app's local server (http://127.0.0.1:1977 by default),
// starting the app if it's installed but not running.
import { getPreferenceValues } from "@raycast/api";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Same presets and instructions as the native Rewrite window (mac/Rewrite.swift).
export const PRESETS = [
  {
    command: "fix-grammar",
    name: "Fix Grammar",
    progress: "Fixing grammar…",
    done: "Fixed grammar",
    instruction: "Fix spelling, grammar and punctuation. Keep the wording and meaning otherwise unchanged.",
  },
  {
    command: "make-shorter",
    name: "Shorter",
    progress: "Shortening…",
    done: "Made shorter",
    instruction: "Make it shorter and more concise. Keep the meaning.",
  },
  {
    command: "make-formal",
    name: "Formal",
    progress: "Making formal…",
    done: "Made formal",
    instruction: "Make it more formal and professional.",
  },
  {
    command: "make-friendly",
    name: "Friendly",
    progress: "Making friendly…",
    done: "Made friendly",
    instruction: "Make it warmer and more friendly.",
  },
] as const;

export type Preset = (typeof PRESETS)[number];

export const INSTALL_COMMAND =
  "curl -fsSL https://github.com/iraosandeep/Orchard/releases/latest/download/install.sh | sh";
export const RELEASES_URL = "https://github.com/iraosandeep/Orchard/releases/latest";

const APP_PATHS = ["/Applications/Orchard.app", join(homedir(), "Applications/Orchard.app")];
// Raycast runs commands with a minimal PATH; the installer needs the system tools.
const PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin";

/** Why Orchard can't be used right now, so the UI can offer the right fix. */
export class OrchardError extends Error {
  constructor(
    message: string,
    readonly kind: "not-installed" | "not-running" | "not-ready" | "request",
  ) {
    super(message);
  }
}

function baseURL(): string {
  const { serverURL } = getPreferenceValues<{ serverURL?: string }>();
  return (serverURL?.trim() || "http://127.0.0.1:1977").replace(/\/+$/, "");
}

export function installedAppPath(): string | undefined {
  return APP_PATHS.find((p) => existsSync(p));
}

/** 200: ready. 503: Orchard runs but fm serve doesn't. undefined: not reachable. */
async function healthStatus(): Promise<number | undefined> {
  try {
    const res = await fetch(`${baseURL()}/api/health`, { signal: AbortSignal.timeout(2000) });
    return res.status;
  } catch {
    return undefined;
  }
}

function run(file: string, args: string[], timeout: number): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { timeout, env: { ...process.env, PATH } }, (err, stdout, stderr) => {
      if (err) reject(new Error((stderr || stdout || err.message).trim().split("\n").pop()));
      else resolve(stdout);
    });
  });
}

/** Opens Orchard in the background (so the frontmost app keeps its selection). */
export async function launchOrchard(): Promise<void> {
  const app = installedAppPath();
  if (!app) throw new OrchardError("Orchard isn't installed.", "not-installed");
  await run("/usr/bin/open", ["-g", app], 10_000);
}

/** Whether the Orchard app (not just a leftover server) is running. */
function appRunning(): Promise<boolean> {
  return new Promise((resolve) =>
    execFile("/usr/bin/pgrep", ["-f", "Orchard.app/Contents/MacOS/Orchard"], (err) => resolve(!err)),
  );
}

/**
 * Makes sure the Orchard app is running and its model is ready: launches the
 * app if it isn't running, then waits for its server and Apple's model.
 */
export async function ensureOrchard(onLaunching?: () => void): Promise<void> {
  let status = await healthStatus();
  const running = await appRunning();
  if (!running || status !== 200) {
    if (!running) {
      if (!installedAppPath()) throw new OrchardError("Orchard isn't installed.", "not-installed");
      onLaunching?.();
      await launchOrchard();
    }
    // The app starts its server, then fm serve; give both time to come up.
    for (let i = 0; i < 40 && status !== 200; i++) {
      await new Promise((r) => setTimeout(r, 500));
      status = await healthStatus();
    }
    if (status === undefined) {
      throw new OrchardError(
        "Orchard didn't start. Open it from Applications and check Setup & Status.",
        "not-running",
      );
    }
  }
  if (status !== 200) {
    throw new OrchardError(
      "Orchard is running but Apple's model isn't ready. Open Orchard › Setup & Status to finish setup.",
      "not-ready",
    );
  }
}

/** Streams a rewrite; onDelta gets the text so far. Resolves with the final text. */
export async function rewrite(
  text: string,
  instruction: string,
  onDelta?: (soFar: string) => void,
  signal?: AbortSignal,
): Promise<string> {
  const res = await fetch(`${baseURL()}/api/rewrite`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text, instruction }),
    signal,
  });
  // 404/405: an Orchard from before /api/rewrite existed.
  if (res.status === 404 || res.status === 405) {
    throw new OrchardError("This Orchard version is too old for Raycast. Update Orchard and try again.", "request");
  }
  if (!res.ok || !res.body) {
    const j = (await res.json().catch(() => ({}))) as { error?: string };
    throw new OrchardError(j.error || `Orchard returned ${res.status}`, "request");
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  let out = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf("\n\n")) >= 0) {
      const block = buf.slice(0, i);
      buf = buf.slice(i + 2);
      let event = "message";
      let data = "";
      for (const line of block.split("\n")) {
        if (line.startsWith("event: ")) event = line.slice(7);
        else if (line.startsWith("data: ")) data += line.slice(6);
      }
      const payload = data ? (JSON.parse(data) as { text?: string; error?: string }) : {};
      if (event === "delta") {
        out += payload.text ?? "";
        onDelta?.(out);
      } else if (event === "done") {
        return payload.text ?? out.trim();
      } else if (event === "error") {
        throw new OrchardError(payload.error || "Rewrite failed", "request");
      }
    }
  }
  return out.trim();
}

/** Runs the official install script (downloads the latest release, installs and opens it). */
export async function installOrchard(): Promise<void> {
  await run("/bin/sh", ["-c", `set -o pipefail 2>/dev/null; ${INSTALL_COMMAND}`], 5 * 60_000);
  if (!installedAppPath()) throw new Error("The installer finished but Orchard.app wasn't found.");
}
