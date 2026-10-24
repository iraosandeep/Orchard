import { Action, ActionPanel, Detail, Icon, Toast, confirmAlert, showToast } from "@raycast/api";
import { useState } from "react";
import { INSTALL_COMMAND, RELEASES_URL, installOrchard, installedAppPath } from "./orchard";

/** Explains what Orchard is and installs it with the official install script. */
export function InstallView(props: { onInstalled?: () => void }) {
  const [installing, setInstalling] = useState(false);
  const installed = !!installedAppPath();

  async function install() {
    const ok = await confirmAlert({
      title: installed ? "Reinstall Orchard?" : "Install Orchard?",
      message: "Downloads the latest release from GitHub, installs it in Applications and opens it.",
      primaryAction: { title: installed ? "Reinstall" : "Install" },
      icon: Icon.Download,
    });
    if (!ok) return;
    setInstalling(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "Installing Orchard…" });
    try {
      await installOrchard();
      toast.style = Toast.Style.Success;
      toast.title = "Orchard installed";
      toast.message = "Finish setup in the Orchard window if it asks.";
      props.onInstalled?.();
    } catch (e) {
      toast.style = Toast.Style.Failure;
      toast.title = "Install failed";
      toast.message = e instanceof Error ? e.message : String(e);
    } finally {
      setInstalling(false);
    }
  }

  const markdown = `# ${installed ? "Orchard is installed" : "Orchard isn't installed"}

These commands use **Orchard**, a free menu-bar app that runs Apple's on-device model. Your text never leaves your Mac.

${installed ? "Reinstalling replaces it with the latest release." : "Install it with one click (↵), or run this in Terminal:"}

\`\`\`sh
${INSTALL_COMMAND}
\`\`\`

**Requires** an Apple Silicon Mac on macOS 26.4 or later, with Apple Intelligence turned on. On first launch Orchard's Setup walks you through anything left to enable.`;

  return (
    <Detail
      isLoading={installing}
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action title={installed ? "Reinstall Orchard" : "Install Orchard"} icon={Icon.Download} onAction={install} />
          <Action.CopyToClipboard title="Copy Install Command" content={INSTALL_COMMAND} />
          <Action.OpenInBrowser title="Open Releases on GitHub" url={RELEASES_URL} />
        </ActionPanel>
      }
    />
  );
}
