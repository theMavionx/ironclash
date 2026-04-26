import { forwardRef, type ButtonHTMLAttributes } from "react";

type ButtonVariant = "primary" | "secondary" | "danger";
type ButtonSize = "sm" | "md" | "lg";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
	variant?: ButtonVariant;
	size?: ButtonSize;
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
	// Sharp rectangle, accent-bordered. Hover fills with accent, text inverts.
	primary:
		"border border-accent text-accent bg-transparent " +
		"hover:bg-accent hover:text-bg " +
		"active:bg-accent-dim active:border-accent-dim active:text-bg",
	secondary:
		"border border-border text-text bg-surface " +
		"hover:bg-surface-2 hover:border-border-strong",
	danger:
		"border border-danger text-danger bg-transparent " +
		"hover:bg-danger hover:text-bg",
};

const SIZE_CLASSES: Record<ButtonSize, string> = {
	sm: "px-4 py-1 text-caption",
	md: "px-6 py-2 text-label",
	lg: "px-8 py-3 text-label",
};

/**
 * Tactical-minimal button per design/gdd/art-bible-ui.md.
 * No rounding, no shadows, transition only on color/border in 120ms.
 */
const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
	{ variant = "primary", size = "md", className = "", children, ...rest },
	ref,
) {
	return (
		<button
			ref={ref}
			className={
				"uppercase tracking-label transition-colors duration-120 " +
				"focus:outline-none focus-visible:ring-1 focus-visible:ring-border-strong focus-visible:ring-offset-2 focus-visible:ring-offset-bg " +
				"disabled:opacity-40 disabled:cursor-not-allowed disabled:hover:bg-transparent " +
				VARIANT_CLASSES[variant] +
				" " +
				SIZE_CLASSES[size] +
				" " +
				className
			}
			{...rest}
		>
			{children}
		</button>
	);
});

export default Button;
