-- Telegram handle for each user (no leading @, lowercase). Used later by a bot that notifies section heads.
-- The handle is NOT verified: a bot cannot message a username, only a chat id, which it only learns
-- after the user starts the bot. Linking and verification are a future step (see ROADMAP.md).
alter table profiles add column telegram_username text;

alter table profiles add constraint profiles_telegram_username_format
  check (telegram_username is null or telegram_username ~ '^[a-z][a-z0-9_]{3,30}[a-z0-9]$');

comment on column profiles.telegram_username is
  'Telegram handle without @, lowercase, 5 to 32 characters. Unverified until a bot links a chat id.';
