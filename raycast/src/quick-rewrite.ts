// Shared by the no-view commands: transform the selection and paste the
// result over it, without opening a window.
import { Clipboard, LaunchType, Toast, getSelectedText, launchCommand, showHUD, showToast } from "@raycast/api";
import { OrchardError, PRESETS, Preset, ensureOrchard, rewrite } from "./orchard";

export function quickRewrite(command: Preset["command"]): Promise<void> {
  const preset = PRESETS.find((p) => p.command === command)!;
  return quickRun({
    progress: preset.progress,
    done: preset.done,
    run: (text) => rewrite(text, preset.instruction),
  });
}

export async function quickRun(job: {
  progress: string;
  done: string;
  run: (text: string) => Promise<string>;
}): Promise<void> {
  let text: string;
  try {
    text = await getSelectedText();
  } catch {
    text = "";
  }
  if (!text.trim()) {
    await showHUD("Select some text first");
    return;
  }

  const toast = await showToast({ style: Toast.Style.Animated, title: job.progress });
  try {
    await ensureOrchard(() => (toast.title = "Starting Orchard…"));
    toast.title = job.progress;
    const result = await job.run(text);
    if (!result) throw new OrchardError("The model returned nothing. Try again.", "request");
    await toast.hide();
    await Clipboard.paste(result);
    await showHUD(job.done);
  } catch (e) {
    if (e instanceof OrchardError && e.kind === "not-installed") {
      await toast.hide();
      await launchCommand({ name: "install-orchard", type: LaunchType.UserInitiated });
      return;
    }
    toast.style = Toast.Style.Failure;
    toast.title = "Failed";
    toast.message = e instanceof Error ? e.message : String(e);
  }
}
