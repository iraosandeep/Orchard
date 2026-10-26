import { getPreferenceValues } from "@raycast/api";
import { translate } from "./orchard";
import { quickRun } from "./quick-rewrite";

export default function Command() {
  const lang = getPreferenceValues<{ translateTo?: string }>().translateTo?.trim() || "English";
  return quickRun({
    progress: `Translating to ${lang}…`,
    done: `Translated to ${lang}`,
    run: (text) => translate(text, lang),
  });
}
