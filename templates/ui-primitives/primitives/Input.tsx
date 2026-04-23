import { forwardRef, type InputHTMLAttributes } from "react";

type InputProps = InputHTMLAttributes<HTMLInputElement>;

const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { className = "", ...rest },
  ref,
) {
  return (
    <input
      ref={ref}
      className={
        "w-full rounded-md border border-hairline bg-card px-3 py-2 " +
        "text-sm text-ink placeholder:text-muted " +
        "transition-[border-color,box-shadow] " +
        "ease-[cubic-bezier(0.32,0.72,0,1)] duration-200 " +
        "focus:outline-none focus:border-ink " +
        "focus:shadow-[0_0_0_1px_var(--color-ink)] " +
        "disabled:opacity-50 disabled:cursor-not-allowed " +
        className
      }
      {...rest}
    />
  );
});

export default Input;
