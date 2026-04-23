interface BadgeProps {
  /** Any CSS color value (hex, rgb, oklch, CSS variable). Projects define
   *  their own domain scales and pass them in. */
  color: string;
  label: string;
}

export default function Badge({ color, label }: BadgeProps) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-hairline bg-card px-2.5 py-0.5 text-[11px] font-medium text-ink">
      <span
        className="w-1.5 h-1.5 rounded-full"
        style={{ backgroundColor: color }}
        aria-hidden="true"
      />
      {label}
    </span>
  );
}
