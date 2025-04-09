# Zig Example Bot

This is a Telegram bot written in Zig. The bot interacts with users by responding to messages that mention it by name or login. It uses an OpenAI-compatible provider to forward messages to an LLM chat model and replies with the result.

## Features
- Responds to messages mentioning the bot by name or login.
- Forwards messages to an LLM chat model using an OpenAI-compatible provider.
- Replies with the model's response.
- Ignores messages without text and replies with "I don't see text."
- Configurable via environment variables.

## Environment Variables
- `TELEGRAM_TOKEN`: Your Telegram bot token (get it from @BotFather).
- `OPENAPI_BASEURL`: Base URL for the OpenAI-compatible API.
- `OPENAPI_TOKEN`: API token for authentication.
- `OPENAPI_MODEL`: Model to use for queries.
- `SYSTEM_MSG`: System message to include in model queries (optional, defaults to "You are a helpful assistant.").

## Local Development
This project uses Docker for development and testing. Podman is recommended for running Docker containers locally.

### Prerequisites
- Podman installed on your system.

### Running Locally
1. Build the Docker image:
   ```sh
   podman build -t zig-example-bot .
   ```
2. Run the container:
   ```sh
   podman run --rm -e TELEGRAM_TOKEN=<telegram_token> -e OPENAPI_BASEURL=<base_url> -e OPENAPI_TOKEN=<token> -e OPENAPI_MODEL=<model> -e SYSTEM_MSG="<system_message>" zig-example-bot
   ```

## How It Works
The bot connects to Telegram's Bot API and periodically polls for new messages. When it receives a message that mentions the bot by username (with or without the @ symbol), it:

1. Extracts the message text excluding the bot mention
2. If there's no text after the mention, it replies with "I don't see text"
3. Otherwise, it forwards the message to the OpenAI-compatible API
4. It then replies to the original message with the model's response

## GitHub Actions
The project includes GitHub Actions workflows to build and push the Docker image to GitHub Container Registry (GHCR).

## License
This project is licensed under the MIT License.