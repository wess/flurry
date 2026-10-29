import { send } from "./api";
import type { User } from "./types";

type Ceremony = {
	challenge_id: string;
	publicKey: Record<string, unknown>;
};

const supported = () =>
	window.isSecureContext && "PublicKeyCredential" in window && "credentials" in navigator;

const decode = (value: string) => {
	const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
	return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
};

const encode = (value: ArrayBuffer | null) => {
	if (!value) return "";
	let binary = "";
	for (const byte of new Uint8Array(value)) binary += String.fromCharCode(byte);
	return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
};

const creationOptions = (value: Record<string, unknown>) => {
	const options = structuredClone(value) as Record<string, any>;
	options.challenge = decode(options.challenge);
	options.user.id = decode(options.user.id);
	options.excludeCredentials = (options.excludeCredentials || []).map(
		(credential: Record<string, unknown>) => ({ ...credential, id: decode(String(credential.id)) }),
	);
	return options as PublicKeyCredentialCreationOptions;
};

const requestOptions = (value: Record<string, unknown>) => {
	const options = structuredClone(value) as Record<string, any>;
	options.challenge = decode(options.challenge);
	return options as PublicKeyCredentialRequestOptions;
};

const unavailable = () =>
	new Error("Passkeys are not available in this browser or connection.");

export async function createPasskey(values: Record<string, unknown>) {
	if (!supported()) throw unavailable();
	const ceremony = await send<Ceremony>("/settings/passkeys/registration/options", values);
	const credential = (await navigator.credentials.create({
		publicKey: creationOptions(ceremony.publicKey),
	})) as PublicKeyCredential | null;
	if (!credential) throw new Error("Passkey creation was cancelled.");
	const response = credential.response as AuthenticatorAttestationResponse;
	return send<{ user: User }>("/settings/passkeys/registration/verify", {
		challenge_id: ceremony.challenge_id,
		name: values.name,
		raw_id: encode(credential.rawId),
		client_data_json: encode(response.clientDataJSON),
		attestation_object: encode(response.attestationObject),
		transports: response.getTransports?.() || [],
	});
}

export async function signInWithPasskey() {
	if (!supported()) throw unavailable();
	const ceremony = await send<Ceremony>("/passkeys/authentication/options");
	const credential = (await navigator.credentials.get({
		publicKey: requestOptions(ceremony.publicKey),
	})) as PublicKeyCredential | null;
	if (!credential) throw new Error("Passkey sign-in was cancelled.");
	const response = credential.response as AuthenticatorAssertionResponse;
	return send<{ user: User }>("/passkeys/authentication/verify", {
		challenge_id: ceremony.challenge_id,
		raw_id: encode(credential.rawId),
		client_data_json: encode(response.clientDataJSON),
		authenticator_data: encode(response.authenticatorData),
		signature: encode(response.signature),
		user_handle: encode(response.userHandle),
	});
}
