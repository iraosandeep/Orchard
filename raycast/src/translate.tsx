// Translate the selection (or clipboard) into a language picked from the list
// or typed in. Recently used languages come first.
import { Action, ActionPanel, Icon, List, LocalStorage } from "@raycast/api";
import { useEffect, useState } from "react";
import { InstallView } from "./install-view";
import { LANGUAGES, translate } from "./orchard";
import { NotReady, ResultView, Source, quote, useOrchard } from "./ui";

const RECENT_KEY = "recentLanguages";

async function remember(lang: string) {
  const recent = JSON.parse((await LocalStorage.getItem<string>(RECENT_KEY)) ?? "[]") as string[];
  const next = [lang, ...recent.filter((l) => l.toLowerCase() !== lang.toLowerCase())].slice(0, 5);
  await LocalStorage.setItem(RECENT_KEY, JSON.stringify(next));
}

export default function Command() {
  const { source, error, check, isLoading } = useOrchard();
  const [search, setSearch] = useState("");
  const [recent, setRecent] = useState<string[]>([]);

  useEffect(() => {
    LocalStorage.getItem<string>(RECENT_KEY).then((v) => setRecent(v ? (JSON.parse(v) as string[]) : []));
  }, []);

  if (error?.kind === "not-installed") return <InstallView onInstalled={check} />;

  const typed = search.trim();
  const all = [...recent, ...LANGUAGES.filter((l) => !recent.some((r) => r.toLowerCase() === l.toLowerCase()))];
  const shown = all.filter((l) => l.toLowerCase().includes(typed.toLowerCase()));
  const custom = typed && !all.some((l) => l.toLowerCase() === typed.toLowerCase()) ? typed : undefined;

  return (
    <List
      isLoading={isLoading}
      filtering={false}
      searchText={search}
      onSearchTextChange={setSearch}
      searchBarPlaceholder="Translate to… (any language)"
      isShowingDetail={!!source && !error}
    >
      {error || source === null ? (
        <NotReady error={error} check={check} command="Translate" />
      ) : source ? (
        <List.Section title={`Translate ${source.from}`} subtitle={`${source.text.length.toLocaleString()} characters`}>
          {[...(custom ? [custom] : []), ...shown].map((lang) => (
            <List.Item
              key={lang}
              icon={lang === custom ? Icon.Pencil : recent.includes(lang) ? Icon.Clock : Icon.Globe}
              title={lang}
              subtitle={lang === custom ? "Quality depends on Apple's model knowing this language" : undefined}
              detail={<List.Item.Detail markdown={quote(source.text)} />}
              actions={
                <ActionPanel>
                  <Action.Push
                    title={`Translate to ${lang}`}
                    icon={Icon.Globe}
                    target={<TranslateResult source={source} lang={lang} />}
                    onPush={() => remember(lang)}
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

function TranslateResult(props: { source: Source; lang: string }) {
  return (
    <ResultView
      source={props.source}
      label="Translate to"
      value={props.lang}
      run={(onDelta, signal) => translate(props.source.text, props.lang, onDelta, signal)}
    />
  );
}
