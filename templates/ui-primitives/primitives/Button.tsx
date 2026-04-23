import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";

export type ButtonVariant =
  | "default"
  | "secondary"
  | "ghost"
  | "outline"
  | "danger";

export type ButtonSize = "sm" | "md" | "lg";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
  children?: ReactNode;
}

const BASE =
  "inline-flex items-center justify-center gap-1.5 rounded-full font-medium tracking-tight border " +
  "transition-[background-color,color,border-color,transform,box-shadow] " +
  "ease-[cubic-bezier(0.32,0.72,0,1)] duration-200 " +
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ink " +
  "focus-visible:ring-offset-2 focus-visible:ring-offset-bg " +
  "disabled:opacity-50 disabled:cursor-not-allowed active:scale-[0.98]";

const VARIANT: Record<ButtonVariant, string> = {
  default: "bg-ink text-card border-transparent hover:bg-ink/90",
  secondary: "bg-card text-ink border-hairline hover:bg-bg",
  ghost: "bg-transparent text-ink border-transparent hover:bg-hairline",
  outline: "bg-transparent text-ink border-ink hover:bg-ink hover:text-card",
  danger: "text-card border-transparent hover:opacity-90",
};

const SIZE: Record<ButtonSize, string> = {
  sm: "text-xs px-3 py-1.5",
  md: "text-sm px-4 py-2",
  lg: "text-base px-5 py-2.5",
};

const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = "default", size = "md", className = "", style, children, ...rest },
  ref,
) {
  const mergedStyle =
    variant === "danger"
      ? { backgroundColor: "var(--color-stance-restrictive)", ...style }
      : style;

  return (
    <button
      ref={ref}
      className={`${BASE} ${VARIANT[variant]} ${SIZE[size]} ${className}`}
      style={mergedStyle}
      {...rest}
    >
      {children}
    </button>
  );
});

export default Button;
