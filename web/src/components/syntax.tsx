import { useMemo } from "react";
import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import elixir from "highlight.js/lib/languages/elixir";
import go from "highlight.js/lib/languages/go";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import kotlin from "highlight.js/lib/languages/kotlin";
import markdown from "highlight.js/lib/languages/markdown";
import php from "highlight.js/lib/languages/php";
import plaintext from "highlight.js/lib/languages/plaintext";
import python from "highlight.js/lib/languages/python";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";

const languages = {
	bash,
	c,
	cpp,
	css,
	diff,
	elixir,
	go,
	java,
	javascript,
	json,
	kotlin,
	markdown,
	php,
	plaintext,
	python,
	ruby,
	rust,
	sql,
	swift,
	typescript,
	xml,
	yaml,
};

for (const [name, grammar] of Object.entries(languages)) hljs.registerLanguage(name, grammar);

const extensions: Record<string, string> = {
	".bash": "bash",
	".c": "c",
	".cc": "cpp",
	".cpp": "cpp",
	".css": "css",
	".diff": "diff",
	".ex": "elixir",
	".exs": "elixir",
	".go": "go",
	".h": "c",
	".hpp": "cpp",
	".html": "xml",
	".java": "java",
	".js": "javascript",
	".json": "json",
	".jsx": "javascript",
	".kt": "kotlin",
	".kts": "kotlin",
	".md": "markdown",
	".mdx": "markdown",
	".php": "php",
	".py": "python",
	".rb": "ruby",
	".rs": "rust",
	".sh": "bash",
	".sql": "sql",
	".swift": "swift",
	".toml": "plaintext",
	".ts": "typescript",
	".tsx": "typescript",
	".xml": "xml",
	".yaml": "yaml",
	".yml": "yaml",
};

const names: Record<string, string> = {
	Dockerfile: "bash",
	Gemfile: "ruby",
	Makefile: "bash",
	Rakefile: "ruby",
};

export const syntaxLanguage = (path: string) => {
	const name = path.split("/").pop() || path;
	if (names[name]) return names[name];
	const dot = name.lastIndexOf(".");
	return extensions[dot >= 0 ? name.slice(dot).toLowerCase() : ""] || "plaintext";
};

export function SyntaxLine({ content, path }: { content: string; path: string }) {
	const html = useMemo(
		() => hljs.highlight(content || " ", { language: syntaxLanguage(path), ignoreIllegals: true }).value,
		[content, path],
	);
	return <code className="syntax" dangerouslySetInnerHTML={{ __html: html }} />;
}

export function SyntaxBlock({ content, path }: { content: string; path: string }) {
	return (
		<div className="codeviewer">
			{content.split("\n").map((line, index) => (
				<div className="codeline" key={index}>
					<span aria-hidden="true">{index + 1}</span>
					<SyntaxLine content={line} path={path} />
				</div>
			))}
		</div>
	);
}
