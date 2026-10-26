// Pieces shared by the Rewrite Selection and Translate commands.
import { Action, ActionPanel, Clipboard, Detail, Icon, Keyboard, List, getSelectedText } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { OrchardError, ensureOrchard, launchOrchard } from "./orchard";

export type Source = { text: string; from: "selection" | "clipboard" };

/** The selected text, or the clipboard if nothing is selected. */
export async function readSource(): Promise<Source | undefined> {
  try {
    const text = await getSelectedText();
    if (text.trim()) return { text, from: "selection" };
  } catch {
    // nothing selected; fall back to the clipboard
  }
  const text = await Clipboard.readText();
  return text?.trim() ? { text, from: "clipboard" } : undefined;
}

/** Reads the source text and makes sure Orchard is running, on mount. */
export function useOrchard() {
  const [source, setSource] = useState<Source | null>();
  const [error, setError] = useState<OrchardError>();
  const [checking, setChecking] = useState(true);

  async function check() {
    setChecking(true);
    setError(undefined);
    try {
      await ensureOrchard();
    } catch (e) {
      setError(e instanceof OrchardError ? e : new OrchardError(String(e), "request"));
    } finally {
      setChecking(false);
    }
  }

  useEffect(() => {
    readSource().then((s) => setSource(s ?? null));
    check();
  }, []);

  return { source, error, check, isLoading: checking || source === undefined };
}

/** Empty states for a List: Orchard not ready, or nothing to work on. */
export function NotReady(props: { error?: OrchardError; check: () => void; command: string }) {
  if (props.error) {
    return (
      <List.EmptyView
        icon={Icon.Warning}
        title="Orchard isn't ready"
        description={props.error.message}
        actions={
          <ActionPanel>
            <Action title="Open Orchard" icon={Icon.AppWindow} onAction={() => launchOrchard().then(props.check)} />
            <Action title="Check Again" icon={Icon.ArrowClockwise} onAction={props.check} />
          </ActionPanel>
        }
      />
    );
  }
  return (
    <List.EmptyView
      icon={Icon.Text}
      title="No text"
      description={`Select some text (or copy it), then run ${props.command} again.`}
    />
  );
}

/**
 * Streams `run`'s output, then offers to paste it over the selection or copy
 * it. `label`/`value` describe what was asked (e.g. "Translate to"/"Spanish").
 */
export function ResultView(props: {
  source: Source;
  label: string;
  value: string;
  run: (onDelta: (soFar: string) => void, signal: AbortSignal) => Promise<string>;
}) {
  const { source, label, value, run } = props;
  const [text, setText] = useState("");
  const [running, setRunning] = useState(true);
  const [error, setError] = useState<string>();
  const [attempt, setAttempt] = useState(0);
  const controller = useRef<AbortController | null>(null);

  useEffect(() => {
    const c = new AbortController();
    controller.current = c;
    setText("");
    setError(undefined);
    setRunning(true);
    run(setText, c.signal)
      .then((out) => !c.signal.aborted && setText(out))
      .catch((e) => !c.signal.aborted && setError(e instanceof Error ? e.message : String(e)))
      .finally(() => !c.signal.aborted && setRunning(false));
    return () => c.abort();
  }, [attempt]);

  const ready = !running && !error && !!text;
  const markdown = error ? `**Failed**\n\n${error}` : text ? escape(text) : "_Working…_";

  return (
    <Detail
      navigationTitle={value}
      isLoading={running}
      markdown={markdown}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title={label} text={value} />
          <Detail.Metadata.Label title="From" text={source.from === "selection" ? "Selection" : "Clipboard"} />
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Original" text={clip(source.text, 300)} />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          {ready && <Action.Paste title={source.from === "selection" ? "Replace Selection" : "Paste"} content={text} />}
          {ready && <Action.CopyToClipboard content={text} />}
          {running ? (
            <Action
              title="Stop"
              icon={Icon.Stop}
              onAction={() => {
                controller.current?.abort();
                setRunning(false);
                if (!text) setError("Stopped.");
              }}
            />
          ) : (
            <Action
              title="Try Again"
              icon={Icon.ArrowClockwise}
              shortcut={Keyboard.Shortcut.Common.Refresh}
              onAction={() => setAttempt((n) => n + 1)}
            />
          )}
        </ActionPanel>
      }
    />
  );
}

// Show text as written, not as Markdown.
function escape(s: string): string {
  return s.replace(/[\\`*_{}[\]()#+\-.!|<>~]/g, "\\$&").replace(/\n/g, "  \n");
}

const clip = (s: string, n: number) => (s.length > n ? s.slice(0, n) + "…" : s);

/** The source text as a list item's detail pane. */
export const quote = (s: string) => escape(clip(s, 4000));
