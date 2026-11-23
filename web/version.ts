// mix.exs is the only place a release bumps the version, so everything the web
// build prints (footer, openapi.json) reads it from there instead of repeating it.
const source = await Bun.file(new URL("../mix.exs", import.meta.url)).text();
const found = source.match(/^\s*version:\s*"([^"]+)"/m)?.[1];
if (!found) throw new Error("mix.exs does not declare a version");

export const version: string = found;
