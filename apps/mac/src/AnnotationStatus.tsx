import { Circle, CircleCheck, CircleDashed, CircleHelp } from "lucide-react";
import type { QueueItem } from "./types";
import { rowIcon, statusText } from "./menu/sections";

/** AnnotationRowView.symbol as a drawn icon: open, in progress, done, or a question for you. */
export function AnnotationStatus({ item, size = 15 }: { item: QueueItem; size?: number }) {
  const kind = rowIcon(item);
  const Icon = { question: CircleHelp, todo: Circle, inProgress: CircleDashed, done: CircleCheck }[kind];
  return <Icon size={size} strokeWidth={1.9} className={`annotation-status ${kind}`} role="img" aria-label={statusText(item)}/>;
}
