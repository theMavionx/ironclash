import GameCanvas from "@/components/GameCanvas";
import HUD from "@/components/HUD";

export default function App() {
	return (
		<div className="relative h-full w-full bg-black">
			<GameCanvas />
			{/* Overlay layer — pointer-events disabled so input falls through to
			    the canvas; individual UI elements re-enable as needed. */}
			<div className="pointer-events-none absolute inset-0">
				<HUD />
			</div>
		</div>
	);
}
