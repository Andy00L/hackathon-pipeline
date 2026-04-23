import Link from "next/link";

interface HeaderItem {
  label: string;
  href: string;
}

interface HeaderProps {
  brand: string;
  brandHref?: string;
  items?: HeaderItem[];
}

export default function Header({
  brand,
  brandHref = "/",
  items = [],
}: HeaderProps) {
  return (
    <header className="h-12 bg-white/70 backdrop-blur-xl border-b border-black/[.06] px-6 flex items-center justify-between fixed top-0 left-0 right-0 z-40">
      <Link href={brandHref} className="text-sm font-semibold text-ink">
        {brand}
      </Link>
      <nav className="flex items-center gap-6 text-xs text-muted">
        {items.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className="hover:text-ink transition-colors"
          >
            {item.label}
          </Link>
        ))}
      </nav>
    </header>
  );
}
