import { Globe2, Link2, Lock } from "lucide-react";
import type { Snippet } from "../../types";

export function Visibility({ value }: { value: Snippet["visibility"] }) {
	const Icon = value === "public" ? Globe2 : value === "unlisted" ? Link2 : Lock;
	return (
		<span className="snippetvisibility">
			<Icon size={12} />
			{value}
		</span>
	);
}
