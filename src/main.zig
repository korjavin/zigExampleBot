const std = @import("std");
const http = @import("std").net.http;
const json = std.json;

// Telegram bot specific constants
const telegram_api_base_url = "https://api.telegram.org/bot";
const polling_timeout = 30; // Seconds

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Read environment variables
    const env = try std.process.env_map(allocator);
    defer env.deinit();

    // Get Telegram token (must be passed as environment variable)
    const telegram_token = env.get("TELEGRAM_TOKEN") orelse {
        std.debug.print("ERROR: TELEGRAM_TOKEN environment variable not set\n", .{});
        return error.MissingTelegramToken;
    };

    // OpenAI settings
    const openapi_baseurl = env.get("OPENAPI_BASEURL") orelse {
        std.debug.print("ERROR: OPENAPI_BASEURL environment variable not set\n", .{});
        return error.MissingOpenAIBaseURL;
    };
    const openapi_token = env.get("OPENAPI_TOKEN") orelse {
        std.debug.print("ERROR: OPENAPI_TOKEN environment variable not set\n", .{});
        return error.MissingOpenAIToken;
    };
    const openapi_model = env.get("OPENAPI_MODEL") orelse {
        std.debug.print("ERROR: OPENAPI_MODEL environment variable not set\n", .{});
        return error.MissingOpenAIModel;
    };
    const system_msg = env.get("SYSTEM_MSG") orelse "You are a helpful assistant.";

    // Get bot info to determine bot username
    std.debug.print("Starting bot...\n", .{});
    const bot_info = try getBotInfo(allocator, telegram_token);
    defer allocator.free(bot_info.username);
    std.debug.print("Bot username: @{s}\n", .{bot_info.username});

    // Real Telegram bot loop
    var last_update_id: i64 = 0;
    
    while (true) {
        // Get updates from Telegram
        const updates = try getUpdates(allocator, telegram_token, last_update_id + 1);
        defer {
            for (updates.items) |update| {
                // Free memory for each message
                if (update.message) |msg| {
                    if (msg.text) |text| {
                        allocator.free(text);
                    }
                    if (msg.from) |from| {
                        allocator.free(from.username);
                        allocator.free(from.first_name);
                    }
                }
            }
            updates.deinit();
        }

        // Process updates
        for (updates.items) |update| {
            // Update the last_update_id to get new updates next time
            last_update_id = @max(last_update_id, update.update_id);

            // Process the message if it exists
            if (update.message) |msg| {
                if (msg.text) |text| {
                    // Check if the message mentions the bot
                    if (isBotMentioned(text, bot_info.username)) {
                        // If message has no content after mention
                        const trimmed_text = trimBotMention(text, bot_info.username);
                        if (trimmed_text.len == 0) {
                            _ = try sendMessage(allocator, telegram_token, msg.chat_id, "I don't see text", msg.message_id);
                            continue;
                        }

                        // Process the message
                        std.debug.print("Processing message: {s}\n", .{trimmed_text});
                        
                        // Query OpenAI API
                        const response = query_openai(allocator, openapi_baseurl, openapi_token, openapi_model, system_msg, trimmed_text) catch |err| {
                            std.debug.print("Error querying OpenAI: {any}\n", .{err});
                            _ = try sendMessage(allocator, telegram_token, msg.chat_id, "Sorry, I encountered an error processing your request.", msg.message_id);
                            continue;
                        };
                        defer allocator.free(response);

                        // Send response back to Telegram
                        _ = try sendMessage(allocator, telegram_token, msg.chat_id, response, msg.message_id);
                    }
                }
            }
        }

        // Sleep for a short time to avoid hammering the Telegram API
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

// Bot information structure
const BotInfo = struct {
    username: []const u8,
};

// Get bot information (username, etc.)
fn getBotInfo(allocator: std.mem.Allocator, token: []const u8) !BotInfo {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}/getMe", .{telegram_api_base_url, token});
    defer allocator.free(url);

    var client = try http.Client.init(allocator);
    defer client.deinit();

    var headers = std.ArrayList(http.Header).init(allocator);
    defer headers.deinit();

    try headers.append(http.Header{ .name = "Content-Type", .value = "application/json" });

    const response = try client.request(.{
        .method = .get,
        .url = url,
        .headers = &headers,
    });
    defer response.deinit();

    if (response.status_code != 200) {
        std.debug.print("Error getting bot info: status code {d}\n", .{response.status_code});
        return error.TelegramApiError;
    }

    const response_body = try response.body.toOwnedSlice(allocator);
    defer allocator.free(response_body);

    // Parse JSON response to get bot username
    var json_parser = std.json.Parser.init(allocator, false);
    defer json_parser.deinit();

    var parsed_data = try json_parser.parse(response_body);
    defer parsed_data.deinit();

    const root = parsed_data.root.Object;
    const result = root.get("result").?.Object;
    const username = try allocator.dupe(u8, result.get("username").?.String);

    return BotInfo{ .username = username };
}

// Telegram Update structure
const Update = struct {
    update_id: i64,
    message: ?Message,
};

// Message structure
const Message = struct {
    message_id: i64,
    chat_id: i64,
    text: ?[]const u8,
    from: ?User,
};

// User structure
const User = struct {
    username: []const u8,
    first_name: []const u8,
};

// Get updates from Telegram
fn getUpdates(allocator: std.mem.Allocator, token: []const u8, offset: i64) !std.ArrayList(Update) {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}/getUpdates?offset={d}&timeout={d}", 
        .{telegram_api_base_url, token, offset, polling_timeout});
    defer allocator.free(url);

    var client = try http.Client.init(allocator);
    defer client.deinit();

    var headers = std.ArrayList(http.Header).init(allocator);
    defer headers.deinit();

    try headers.append(http.Header{ .name = "Content-Type", .value = "application/json" });

    const response = try client.request(.{
        .method = .get,
        .url = url,
        .headers = &headers,
    });
    defer response.deinit();

    if (response.status_code != 200) {
        std.debug.print("Error getting updates: status code {d}\n", .{response.status_code});
        return error.TelegramApiError;
    }

    const response_body = try response.body.toOwnedSlice(allocator);
    defer allocator.free(response_body);

    // Parse JSON response
    var json_parser = std.json.Parser.init(allocator, false);
    defer json_parser.deinit();

    var parsed_data = try json_parser.parse(response_body);
    defer parsed_data.deinit();

    // Extract updates from the JSON
    var updates = std.ArrayList(Update).init(allocator);
    errdefer updates.deinit();

    const root = parsed_data.root.Object;
    const result = root.get("result").?.Array;

    for (result.items) |item| {
        const update_obj = item.Object;
        var update = Update{
            .update_id = update_obj.get("update_id").?.Integer,
            .message = null,
        };

        if (update_obj.get("message")) |msg_value| {
            const msg_obj = msg_value.Object;
            var message = Message{
                .message_id = msg_obj.get("message_id").?.Integer,
                .chat_id = msg_obj.get("chat").?.Object.get("id").?.Integer,
                .text = null,
                .from = null,
            };

            if (msg_obj.get("text")) |text_value| {
                message.text = try allocator.dupe(u8, text_value.String);
            }

            if (msg_obj.get("from")) |from_value| {
                const from_obj = from_value.Object;
                var user = User{
                    .username = "",
                    .first_name = "",
                };

                if (from_obj.get("username")) |username_value| {
                    user.username = try allocator.dupe(u8, username_value.String);
                } else {
                    user.username = try allocator.dupe(u8, "");
                }

                if (from_obj.get("first_name")) |first_name_value| {
                    user.first_name = try allocator.dupe(u8, first_name_value.String);
                } else {
                    user.first_name = try allocator.dupe(u8, "");
                }

                message.from = user;
            }

            update.message = message;
        }

        try updates.append(update);
    }

    return updates;
}

// Check if the bot is mentioned in the message
fn isBotMentioned(text: []const u8, botUsername: []const u8) bool {
    // Check if the text contains the bot's username (with or without @ symbol)
    const with_at = std.mem.indexOf(u8, text, std.fmt.allocPrint(std.heap.page_allocator, "@{s}", .{botUsername}) catch unreachable) != null;
    const without_at = std.mem.indexOf(u8, text, botUsername) != null;
    return with_at or without_at;
}

// Remove bot mention from the text
fn trimBotMention(text: []const u8, botUsername: []const u8) []const u8 {
    const with_at = std.fmt.allocPrint(std.heap.page_allocator, "@{s}", .{botUsername}) catch unreachable;
    defer std.heap.page_allocator.free(with_at);
    
    if (std.mem.indexOf(u8, text, with_at)) |index| {
        return std.mem.trim(u8, text[index + with_at.len..], " \t\n\r");
    }
    
    if (std.mem.indexOf(u8, text, botUsername)) |index| {
        return std.mem.trim(u8, text[index + botUsername.len..], " \t\n\r");
    }
    
    return text;
}

// Send a message to a Telegram chat
fn sendMessage(allocator: std.mem.Allocator, token: []const u8, chat_id: i64, text: []const u8, reply_to_message_id: i64) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}/sendMessage", .{telegram_api_base_url, token});
    defer allocator.free(url);

    var client = try http.Client.init(allocator);
    defer client.deinit();

    var headers = std.ArrayList(http.Header).init(allocator);
    defer headers.deinit();

    try headers.append(http.Header{ .name = "Content-Type", .value = "application/json" });

    const body = try std.fmt.allocPrint(allocator, 
        "{{\"chat_id\":{d},\"text\":\"{s}\",\"reply_to_message_id\":{d}}}", 
        .{chat_id, text, reply_to_message_id});
    defer allocator.free(body);

    const response = try client.request(.{
        .method = .post,
        .url = url,
        .headers = &headers,
        .body = body,
    });
    defer response.deinit();

    if (response.status_code != 200) {
        std.debug.print("Error sending message: status code {d}\n", .{response.status_code});
        return error.TelegramApiError;
    }

    return try response.body.toOwnedSlice(allocator);
}

fn query_openai(allocator: std.mem.Allocator, baseurl: []const u8, token: []const u8, model: []const u8, system_msg: []const u8, query: []const u8) ![]const u8 {
    var client = try http.Client.init(allocator);
    defer client.deinit();

    var headers = std.ArrayList(http.Header).init(allocator);
    defer headers.deinit();

    try headers.append(http.Header{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) });
    try headers.append(http.Header{ .name = "Content-Type", .value = "application/json" });

    const body = try std.fmt.allocPrint(allocator, 
        "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"system\",\"content\":\"{s}\"}},{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", 
        .{model, system_msg, query});
    defer allocator.free(body);

    const response = try client.request(.{
        .method = .post,
        .url = baseurl,
        .headers = &headers,
        .body = body,
    });
    defer response.deinit();

    if (response.status_code != 200) {
        std.debug.print("Error from OpenAI API: status code {d}\n", .{response.status_code});
        return error.OpenAIApiError;
    }

    const response_body = try response.body.toOwnedSlice(allocator);
    
    // Parse JSON to extract the response content
    var json_parser = std.json.Parser.init(allocator, false);
    defer json_parser.deinit();

    var parsed_data = try json_parser.parse(response_body);
    defer parsed_data.deinit();
    defer allocator.free(response_body);

    const root = parsed_data.root.Object;
    const choices = root.get("choices").?.Array;
    const first_choice = choices.items[0].Object;
    const message = first_choice.get("message").?.Object;
    const content = message.get("content").?.String;
    
    return try allocator.dupe(u8, content);
}