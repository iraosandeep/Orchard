// Like Orchard's native Rewrite window: pick a preset or type an instruction,
// watch the result stream in, then paste it over the selection or copy it.
import { Action, ActionPanel, Clipboard, Detail, Icon, Keyboard, List, getSelectedText } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { InstallView } from "./install-view";
import { OrchardError, PRESETS, ensureOrchard, launchOrchard, rewrite } from "./orchard";

type Source = { text: string; from: "selection" | "clipboard" };

async function readSource(): Promise<Source | undefined> {
  try {
    const text = await getSelectedText();
    if (text.trim()) return { text, from: "selection" };
  } catch {
    // nothing selected; fall back to the clipboard
  }
  const text = await Clipboard.readText();
  return text?.trim() ? { text, from: "clipboard" } : undefined;
}

export default function Command() {
  const [source, setSource] = useState<Source | null>();
  const [error, setError] = useState<OrchardError>();
  const [checking, setChecking] = useState(true);
  const [instruction, setInstruction] = useState("");

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

  if (error?.kind === "not-installed") return <InstallView onInstalled={check} />;

  const custom = instruction.trim();
  const isLoading = checking || source === undefined;
  const chars = source ? `${source.text.length.toLocaleString()} characters` : "";

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      searchText={instruction}
      onSearchTextChange={setInstruction}
      searchBarPlaceholder="Or describe a change…"
      isShowingDetail={!!source && !error}
    >
      {error ? (
        <List.EmptyView
          icon={Icon.Warning}
          title="Orchard isn't ready"
          description={error.message}
          actions={
            <ActionPanel>
              <Action title="Open Orchard" icon={Icon.AppWindow} onAction={() => launchOrchard().then(check)} />
              <Action title="Check Again" icon={Icon.ArrowClockwise} onAction={check} />
            </ActionPanel>
          }
        />
      ) : source === null ? (
        <List.EmptyView
          icon={Icon.Text}
          title="Nothing to rewrite"
          description="Select some text (or copy it), then run Rewrite Selection again."
        />
      ) : source ? (
        <List.Section title={`Rewrite ${source.from === "selection" ? "selection" : "clipboard"}`} subtitle={chars}>
          {custom && (
            <List.Item
              key="custom"
              icon={Icon.Pencil}
              title={custom}
              detail={<List.Item.Detail markdown={quote(source.text)} />}
              actions={
                <ActionPanel>
                  <Action.Push
                    title="Rewrite"
                    icon={Icon.Wand}
                    target={<Result source={source} title={custom} instruction={custom} />}
                  />
                </ActionPanel>
              }
            />
          )}
          {PRESETS.map((p) => (
            <List.Item
              key={p.command}
              icon={Icon.Wand}
              title={p.name}
              detail={<List.Item.Detail markdown={quote(source.text)} />}
              actions={
                <ActionPanel>
                  <Action.Push
                    title={p.name}
                    icon={Icon.Wand}
                    target={<Result source={source} title={p.name} instruction={p.instruction} />}
                  />
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      ) : null}
    </List>
  );
}

function Result(props: { source: Source; title: string; instruction: string }) {
  const { source, title, instruction } = props;
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
    rewrite(source.text, instruction, setText, c.signal)
      .then((out) => !c.signal.aborted && setText(out))
      .catch((e) => !c.signal.aborted && setError(e instanceof Error ? e.message : String(e)))
      .finally(() => !c.signal.aborted && setRunning(false));
    return () => c.abort();
  }, [attempt]);

  const ready = !running && !error && !!text;
  const markdown = error ? `**Rewrite failed**\n\n${error}` : text ? escape(text) : "_Rewriting…_";

  return (
    <Detail
      navigationTitle={title}
      isLoading={running}
      markdown={markdown}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label title="Instruction" text={title} />
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
const quote = (s: string) => escape(clip(s, 4000));
