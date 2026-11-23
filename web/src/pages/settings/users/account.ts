export type Account = {
	id: string;
	username: string;
	name: string;
	admin: boolean;
	owner: boolean;
	founder: boolean;
	disabled: boolean;
};

export type AccountDetail = Account & {
	email: string;
	email_verified: boolean;
	bio: string;
	location: string;
	website: string;
	account_type: "human" | "agent";
	private_profile: boolean;
	hide_activity: boolean;
	joined_at: string;
	two_factor: boolean;
	passkeys: number;
	sessions: number;
	tokens: number;
	repositories: number;
	storage_bytes: number;
};

export const role = (account: Account) =>
	account.founder
		? "founding owner"
		: account.owner
			? "instance owner"
			: account.admin
				? "administrator"
				: "";

const units = ["B", "KiB", "MiB", "GiB", "TiB"];

export const size = (bytes: number) => {
	const step = Math.min(
		units.length - 1,
		bytes > 0 ? Math.floor(Math.log2(bytes) / 10) : 0,
	);
	return `${Number((bytes / 1024 ** step).toFixed(2))} ${units[step]}`;
};
