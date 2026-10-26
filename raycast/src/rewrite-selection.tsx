// Like Orchard's native Rewrite window: pick a preset or type an instruction,
// watch the result stream in, then paste it over the selection or copy it.
import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { useState } from "react";
import { InstallView } from "./install-view";
import { PRESETS, rewrite } from "./orchard";
import { NotReady, ResultView, Source, quote, useOrchard } from "./ui";

export default function Command() {
  const { source, error, check, isLoading } = useOrchard();
  const [instruction, setInstruction] = useState("");

  if (error?.kind === "not-installed") return <InstallView onInstalled={check} />;

  const custom = instruction.trim();
  const items = [
    ...(custom ? [{ key: "custom", name: custom, instruction: custom, icon: Icon.Pencil }] : []),
    ...PRESETS.map((p) => ({ key: p.command, name: p.name, instruction: p.instruction, icon: Icon.Wand })),
  ];

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      searchText={instruction}
      onSearchTextChange={setInstruction}
      searchBarPlaceholder="Or describe a change…"
      isShowingDetail={!!source && !error}
    >
      {error || source === null ? (
        <NotReady error={error} check={check} command="Rewrite Selection" />
      ) : source ? (
        <List.Section title={`Rewrite ${source.from}`} subtitle={`${source.text.length.toLocaleString()} characters`}>
          {items.map((it) => (
            <List.Item
              key={it.key}
              icon={it.icon}
              title={it.name}
              detail={<List.Item.Detail markdown={quote(source.text)} />}
              actions={
                <ActionPanel>
                  <Action.Push
                    title={it.key === "custom" ? "Rewrite" : it.name}
                    icon={Icon.Wand}
                    target={<RewriteResult source={source} name={it.name} instruction={it.instruction} />}
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

function RewriteResult(props: { source: Source; name: string; instruction: string }) {
  return (
    <ResultView
      source={props.source}
      label="Instruction"
      value={props.name}
      run={(onDelta, signal) => rewrite(props.source.text, props.instruction, onDelta, signal)}
    />
  );
}
