import { endpointGroups } from "./src/pages/docs-data";

const publicOperations = new Set([
	"GET /health",
	"GET /session",
	"POST /setup",
	"POST /signup",
	"POST /login",
	"POST /passkeys/authentication/options",
	"POST /passkeys/authentication/verify",
	"POST /email/verify",
	"POST /password/reset-request",
	"POST /password/reset",
	"GET /profiles/{username}",
	"GET /explore",
	"GET /snippets",
	"GET /snippets/{slug}",
	"GET /snippets/{slug}/raw/{path}",
	"GET /source-connections/callback",
]);

const browserOnly = (method: string, path: string) =>
	(!path.startsWith("/repositories") &&
		!path.startsWith("/snippets") &&
		path !== "/explore") ||
	(method !== "GET" &&
		(path.includes("/lifecycle") ||
			path.includes("/members") ||
			path.includes("/source/") ||
			/^\/repositories\/\{id\}$/.test(path)));

const requestSchemas: Record<string, object> = {
	"POST /repositories": { $ref: "#/components/schemas/CreateRepository" },
	"POST /imports": { $ref: "#/components/schemas/ImportRepository" },
	"POST /repositories/{id}/changesets": {
		$ref: "#/components/schemas/SubmitChangeset",
	},
	"PUT /repositories/{id}/changesets/{change}/statuses": {
		$ref: "#/components/schemas/CommitStatusInput",
	},
	"POST /repositories/{id}/changesets/{change}/evaluations": {
		$ref: "#/components/schemas/EvaluationInput",
	},
	"POST /repositories/{id}/webhooks": {
		$ref: "#/components/schemas/WebhookInput",
	},
};

const pathParameters = (path: string) =>
	[...path.matchAll(/\{([^}]+)\}/g)].map((match) => ({
		name: match[1],
		in: "path",
		required: true,
		description: match[1] === "id" ? "Repository UUID" : `${match[1]} identifier`,
		schema: { type: "string" },
	}));

const queryParameters: Record<string, object[]> = {
	"GET /notifications": [{ name: "unread", in: "query", schema: { type: "boolean" } }],
	"GET /repositories/{id}/tree": [
		{ name: "revision", in: "query", schema: { type: "string" } },
		{ name: "path", in: "query", schema: { type: "string" } },
	],
	"GET /repositories/{id}/file": [
		{ name: "revision", in: "query", schema: { type: "string" } },
		{ name: "path", in: "query", required: true, schema: { type: "string" } },
		{ name: "preview", in: "query", schema: { type: "boolean" } },
		{ name: "raw", in: "query", schema: { type: "boolean" } },
	],
	"GET /repositories/{id}/compare": [
		{ name: "base", in: "query", required: true, schema: { type: "string" } },
		{ name: "head", in: "query", required: true, schema: { type: "string" } },
	],
	"GET /repositories/{id}/search": [
		{
			name: "query",
			in: "query",
			required: true,
			schema: { type: "string", maxLength: 200 },
		},
		{
			name: "type",
			in: "query",
			schema: { type: "string", enum: ["code", "path"], default: "code" },
		},
		{ name: "revision", in: "query", schema: { type: "string" } },
	],
};

const paths: Record<string, Record<string, object>> = {};
for (const [tag, access, endpoints] of endpointGroups) {
	for (const [method, path, description] of endpoints) {
		if (!method || !path || !description) continue;
		const key = `${method} ${path}`;
		const operation: Record<string, unknown> = {
			tags: [tag],
			summary: description,
			description: `${description}. Access: ${access}.`,
			operationId: `${method.toLowerCase()}${path.replace(/\{([^}]+)\}/g, "By_$1").replace(/[^a-zA-Z0-9]+(.)/g, (_, next: string) => next.toUpperCase())}`,
			parameters: [...pathParameters(path), ...(queryParameters[key] || [])],
			responses: {
				"200": {
					description: "Successful response",
					content: {
						"application/json": {
							schema: { $ref: "#/components/schemas/JsonObject" },
						},
					},
				},
				"201": {
					description: "Created",
					content: {
						"application/json": {
							schema: { $ref: "#/components/schemas/JsonObject" },
						},
					},
				},
				"202": {
					description: "Accepted for asynchronous processing",
					content: {
						"application/json": {
							schema: { $ref: "#/components/schemas/JsonObject" },
						},
					},
				},
				"400": { $ref: "#/components/responses/Error" },
				"401": { $ref: "#/components/responses/Error" },
				"403": { $ref: "#/components/responses/Error" },
				"404": { $ref: "#/components/responses/Error" },
				"409": { $ref: "#/components/responses/Error" },
				"413": { $ref: "#/components/responses/Error" },
				"429": { $ref: "#/components/responses/Error" },
			},
		};
		if (publicOperations.has(key)) operation.security = [];
		else if (browserOnly(method, path)) operation.security = [{ cookieSession: [] }];
		else operation.security = [{ bearerToken: [] }, { cookieSession: [] }];
		if (!["GET", "DELETE"].includes(method) && path !== "/source-connections/callback") {
			operation.requestBody = {
				required: true,
				content: {
					"application/json": {
						schema: requestSchemas[key] || {
							$ref: "#/components/schemas/JsonObject",
						},
					},
				},
			};
		}
		if (key === "POST /repositories/{id}/changesets") {
			(operation.parameters as object[]).push({
				name: "Idempotency-Key",
				in: "header",
				required: false,
				schema: { type: "string", maxLength: 200 },
				description: "Stable key for safe submission retries",
			});
		}
		(paths[`/api${path}`] ||= {})[method.toLowerCase()] = operation;
	}
}

export const openapi = {
	openapi: "3.1.0",
	info: {
		title: "Flurry HTTP API",
		version: "0.1.2",
		description:
			"Repository, review, collaboration, and automation API for Flurry. Use expiring, narrowly scoped tokens for integrations. Browser-only operations are marked with cookieSession security.",
		contact: { email: "me@wess.io" },
		license: { name: "Apache License 2.0", identifier: "Apache-2.0" },
	},
	servers: [{ url: "/", description: "This Flurry instance" }],
	tags: endpointGroups.map(([name, description]) => ({ name, description })),
	paths,
	components: {
		securitySchemes: {
			bearerToken: {
				type: "http",
				scheme: "bearer",
				bearerFormat: "flr_…",
				description: "Expiring API token created in Settings → Access",
			},
			cookieSession: {
				type: "apiKey",
				in: "cookie",
				name: "flurry",
				description: "HTTP-only same-origin browser session",
			},
		},
		responses: {
			Error: {
				description: "Request failed",
				content: {
					"application/json": {
						schema: { $ref: "#/components/schemas/Error" },
					},
				},
			},
		},
		schemas: {
			JsonObject: { type: "object", additionalProperties: true },
			Error: {
				type: "object",
				required: ["error"],
				properties: { error: { type: "string" }, details: {} },
			},
			CreateRepository: {
				type: "object",
				required: ["name"],
				additionalProperties: false,
				properties: {
					name: {
						type: "string",
						maxLength: 80,
						pattern: "^[a-z0-9][a-z0-9.]*$",
					},
					description: { type: "string", maxLength: 500 },
					visibility: { type: "string", enum: ["public", "private"] },
					organization_id: { type: ["string", "null"], format: "uuid" },
					readme: { type: "boolean" },
					ignore: { type: "string" },
					license: { type: "string" },
				},
			},
			ImportRepository: {
				type: "object",
				required: ["url"],
				additionalProperties: true,
				properties: {
					url: { type: "string", format: "uri" },
					branch: { type: "string" },
					name: { type: "string", maxLength: 80 },
					visibility: { type: "string", enum: ["public", "private"] },
					connection_id: { type: ["string", "null"], format: "uuid" },
					username: { type: "string" },
					token: { type: "string", writeOnly: true },
				},
			},
			FileChange: {
				type: "object",
				required: ["path"],
				additionalProperties: false,
				properties: {
					path: { type: "string" },
					content: {
						type: ["string", "null"],
						description: "UTF-8 file contents, or null to delete",
					},
					base64: {
						type: "string",
						contentEncoding: "base64",
						description: "Binary contents; mutually exclusive with content",
					},
				},
			},
			SubmitChangeset: {
				type: "object",
				required: ["base", "message", "files"],
				additionalProperties: false,
				properties: {
					base: {
						type: ["string", "null"],
						description: "Exact parent changeset, or null for an empty repository",
					},
					message: { type: "string", maxLength: 2000 },
					files: {
						type: "array",
						minItems: 1,
						maxItems: 100,
						items: { $ref: "#/components/schemas/FileChange" },
					},
					signature: { type: "string" },
					automation: { $ref: "#/components/schemas/AutomationProvenance" },
				},
			},
			AutomationProvenance: {
				type: "object",
				required: ["name"],
				additionalProperties: false,
				properties: {
					name: { type: "string", maxLength: 120 },
					version: { type: "string", maxLength: 120 },
					trigger: { type: "string", maxLength: 40, default: "api" },
					external_id: { type: "string", maxLength: 200 },
					metadata: {
						type: "object",
						maxProperties: 100,
						additionalProperties: true,
					},
				},
			},
			CommitStatusInput: {
				type: "object",
				required: ["context", "state"],
				additionalProperties: false,
				properties: {
					context: { type: "string", maxLength: 100 },
					state: {
						type: "string",
						enum: ["pending", "success", "failure", "error"],
					},
					description: { type: "string", maxLength: 500 },
					target_url: {
						type: ["string", "null"],
						format: "uri",
						maxLength: 2000,
					},
				},
			},
			EvaluationInput: {
				type: "object",
				required: ["context", "state"],
				additionalProperties: false,
				properties: {
					context: { type: "string", maxLength: 100 },
					state: { type: "string", enum: ["success", "failure", "error"] },
					summary: { type: "string", maxLength: 500 },
					score: { type: ["number", "null"] },
					pass: { type: "integer", minimum: 0, maximum: 1000000 },
					fail: { type: "integer", minimum: 0, maximum: 1000000 },
					duration_ms: { type: ["integer", "null"], minimum: 0 },
					metrics: { type: "object", additionalProperties: true },
					target_url: {
						type: ["string", "null"],
						format: "uri",
						maxLength: 2000,
					},
					external_id: { type: ["string", "null"], maxLength: 200 },
				},
			},
			WebhookInput: {
				type: "object",
				required: ["url"],
				additionalProperties: false,
				properties: {
					url: { type: "string", format: "uri" },
					events: { type: "array", items: { type: "string" }, default: ["*"] },
				},
			},
		},
	},
} as const;
