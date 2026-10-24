import { popToRoot } from "@raycast/api";
import { InstallView } from "./install-view";

export default function Command() {
  return <InstallView onInstalled={() => popToRoot()} />;
}
