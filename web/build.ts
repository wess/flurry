import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { openapi } from "./openapi";

await mkdir("../priv/static/assets", { recursive: true });
const result = await Bun.build({
	entrypoints: ["./src/index.tsx"],
	outdir: "../priv/static/assets",
	target: "browser",
	minify: true,
	naming: "[name].[ext]",
	define: { "process.env.NODE_ENV": '"production"' },
});
if (!result.success) {
	console.error(result.logs);
	process.exit(1);
}
await writeFile(
	"../priv/static/index.html",
	await Bun.file("index.html").text(),
);
await writeFile("../priv/static/openapi.json", `${JSON.stringify(openapi, null, 2)}\n`);

await Promise.all([
	copyFile("favicon.svg", "../priv/static/favicon.svg"),
	copyFile("robots.txt", "../priv/static/robots.txt"),
	copyFile("sitemap.xml", "../priv/static/sitemap.xml"),
	copyFile("llms.txt", "../priv/static/llms.txt"),
	copyFile("llms.txt", "../priv/static/llm.txt"),
]);
