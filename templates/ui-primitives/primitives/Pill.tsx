import type { ReactNode } from "react";

export type PillTone = "neutral" | "info" | "warn" | "success" | "danger";

interface PillProps {
  tone?: PillTone;
  label: string;
  icon?: ReactNode;
}

const TONE_COLOR: Record<PillTone, string> = {
  neutral: "var(--color-muted)",
  info: "var(--color-stance-review)",
  warn: "var(--color-stance-concerning)",
  success: "var(--color-stance-favorable)",
  danger: "var(--color-stance-restrictive)",
};

export default function Pill({ tone = "neutral", label, icon }: PillProps) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-hairline bg-card px-2.5 py-0.5 text-[11px] font-medium text-ink">
      {icon ? (
        <span
          className="flex items-center"
          style={{ color: TONE_COLOR[tone] }}
          aria-hidden="true"
        >
          {icon}
        </span>
      ) : (
        <span
          className="w-1.5 h-1.5 rounded-full"
          style={{ backgroundColor: TONE_COLOR[tone] }}
          aria-hidden="true"
        />
      )}
      {label}
    </span>
  );
}
