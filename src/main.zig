const std = @import("std");

// Telegram bot specific constants
const telegram_api_base_url = "https://api.telegram.org/bot";
const polling_timeout = 30; // Seconds

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Read environment variables - fix for older Zig versions
    var env_map = std.process.getEnvMap(allocator) catch |err| {
        std.debug.print("Failed to get environment variables: {any}\n", .{err});
        return err;
    };
    defer env_map.deinit();

    // Get Telegram token (must be passed as environment variable)
    const telegram_token = env_map.get("TELEGRAM_TOKEN") orelse {
        std.debug.print("ERROR: TELEGRAM_TOKEN environment variable not set\n", .{});
        return error.MissingTelegramToken;
    };

    // OpenAI settings
    const openapi_baseurl = env_map.get("OPENAPI_BASEURL") orelse {
        std.debug.print("ERROR: OPENAPI_BASEURL environment variable not set\n", .{});
        return error.MissingOpenAIBaseURL;
    };
    const openapi_token = env_map.get("OPENAPI_TOKEN") orelse {
        std.debug.print("ERROR: OPENAPI_TOKEN environment variable not set\n", .{});
        return error.MissingOpenAIToken;
    };
    const openapi_model = env_map.get("OPENAPI_MODEL") orelse {
        std.debug.print("ERROR: OPENAPI_MODEL environment variable not set\n", .{});
        return error.MissingOpenAIModel;
    };
    const system_msg = env_map.get("SYSTEM_MSG") orelse "You are a helpful assistant.";

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

        updates.deinit();

        // Sleep for a short time to avoid hammering the Telegram API
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

// Bot information structure
const BotInfo = struct {
    username: []const u8,
};

// Get bot information (username, etc.) using curl
fn getBotInfo(allocator: std.mem.Allocator, token: []const u8) !BotInfo {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}/getMe", .{telegram_api_base_url, token});
    defer allocator.free(url);

    const response = try curlRequest(allocator, .{
        .method = "GET",
        .url = url,
        .body = null,
        .headers = &[_][]const u8{"Content-Type: application/json"},
    });
    defer allocator.free(response);

    // Parse JSON response manually to extract bot username
    // Look for "username":"BOTNAME" pattern
    const username_prefix = "\"username\":\"";
    if (std.mem.indexOf(u8, response, username_prefix)) |username_start| {
        const start_idx = username_start + username_prefix.len;
        const end_idx = std.mem.indexOfPos(u8, response, start_idx, "\"") orelse return error.InvalidResponse;
        return BotInfo{
            .username = try allocator.dupe(u8, response[start_idx..end_idx]),
        };
    } else {
        return error.UsernameNotFound;
    }
}

// Simple update structure
const Update = struct {
    update_id: i64,
    message: ?Message,
};

// Message structure
const Message = struct {
    message_id: i64,
    chat_id: i64,
    text: ?[]const u8,
};

const ArrayList = std.ArrayList;

// Get updates from Telegram using curl
fn getUpdates(allocator: std.mem.Allocator, token: []const u8, offset: i64) !ArrayList(Update) {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}/getUpdates?offset={d}&timeout={d}",
        .{telegram_api_base_url, token, offset, polling_timeout});
    defer allocator.free(url);

    const response = try curlRequest(allocator, .{
        .method = "GET",
        .url = url,
        .body = null,
        .headers = &[_][]const u8{"Content-Type: application/json"},
    });
    defer allocator.free(response);

    // Parse JSON response manually to extract updates
    var updates = ArrayList(Update).init(allocator);
    errdefer updates.deinit();

    // Locate the "result" array
    const result_start = std.mem.indexOf(u8, response, "\"result\":[") orelse return updates;
    var json_pos = result_start + "\"result\":[".len;

    // Parse each update object
    while (json_pos < response.len) {
        // Find the start of the update object
        const update_start = std.mem.indexOfPos(u8, response, json_pos, "{") orelse break;
        json_pos = update_start + 1;

        // Find the end of this update object
        var brace_depth: usize = 1;
        var update_end: usize = update_start + 1;
        while (brace_depth > 0 and update_end < response.len) {
            if (response[update_end] == '{') {
                brace_depth += 1;
            } else if (response[update_end] == '}') {
                brace_depth -= 1;
            }
            update_end += 1;
        }
        
        if (brace_depth != 0) break; // Malformed JSON
        
        // Extract update_id
        const update_id_prefix = "\"update_id\":";
        const update_id_start = std.mem.indexOfPos(u8, response, update_start, update_id_prefix) orelse break;
        const id_start = update_id_start + update_id_prefix.len;
        const id_end = std.mem.indexOfPos(u8, response, id_start, ",") orelse std.mem.indexOfPos(u8, response, id_start, "}") orelse break;
        
        const update_id_str = std.mem.trim(u8, response[id_start..id_end], " \t\n\r");
        const update_id = std.fmt.parseInt(i64, update_id_str, 10) catch break;
        
        // Create a new update
        var update = Update{
            .update_id = update_id,
            .message = null,
        };
        
        // Look for message
        const message_start = std.mem.indexOfPos(u8, response, update_start, "\"message\":{") orelse {
            try updates.append(update);
            json_pos = update_end;
            continue;
        };
        
        // Extract message_id
        const message_id_prefix = "\"message_id\":";
        const message_id_start = std.mem.indexOfPos(u8, response, message_start, message_id_prefix) orelse {
            try updates.append(update);
            json_pos = update_end;
            continue;
        };
        
        const msg_id_start = message_id_start + message_id_prefix.len;
        const msg_id_end = std.mem.indexOfPos(u8, response, msg_id_start, ",") orelse std.mem.indexOfPos(u8, response, msg_id_start, "}") orelse break;
        
        const message_id_str = std.mem.trim(u8, response[msg_id_start..msg_id_end], " \t\n\r");
        const message_id = std.fmt.parseInt(i64, message_id_str, 10) catch break;
        
        // Extract chat_id
        const chat_id_prefix = "\"chat\":{\"id\":";
        const chat_id_start = std.mem.indexOfPos(u8, response, message_start, chat_id_prefix) orelse {
            try updates.append(update);
            json_pos = update_end;
            continue;
        };
        
        const chat_id_value_start = chat_id_start + chat_id_prefix.len;
        const chat_id_end = std.mem.indexOfPos(u8, response, chat_id_value_start, ",") orelse std.mem.indexOfPos(u8, response, chat_id_value_start, "}") orelse break;
        
        const chat_id_str = std.mem.trim(u8, response[chat_id_value_start..chat_id_end], " \t\n\r");
        const chat_id = std.fmt.parseInt(i64, chat_id_str, 10) catch break;
        
        // Look for text
        var text: ?[]const u8 = null;
        const text_prefix = "\"text\":\"";
        if (std.mem.indexOfPos(u8, response, message_start, text_prefix)) |text_start| {
            const text_content_start = text_start + text_prefix.len;
            var text_end = text_content_start;
            var escaped = false;
            
            // Find the closing quote, handling escaped quotes
            while (text_end < response.len) {
                if (response[text_end] == '\\') {
                    escaped = !escaped;
                } else if (response[text_end] == '"' and !escaped) {
                    break;
                } else {
                    escaped = false;
                }
                text_end += 1;
            }
            
            if (text_end < response.len) {
                text = try allocator.dupe(u8, response[text_content_start..text_end]);
            }
        }
        
        // Create the message
        update.message = Message{
            .message_id = message_id,
            .chat_id = chat_id,
            .text = text,
        };
        
        try updates.append(update);
        json_pos = update_end;
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

// Send a message to a Telegram chat using curl
fn sendMessage(allocator: std.mem.Allocator, token: []const u8, chat_id: i64, text: []const u8, reply_to_message_id: i64) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}{s}/sendMessage", .{telegram_api_base_url, token});
    defer allocator.free(url);

    const body = try std.fmt.allocPrint(allocator, 
        "{{\"chat_id\":{d},\"text\":\"{s}\",\"reply_to_message_id\":{d}}}", 
        .{chat_id, text, reply_to_message_id});
    defer allocator.free(body);

    return try curlRequest(allocator, .{
        .method = "POST",
        .url = url,
        .body = body,
        .headers = &[_][]const u8{"Content-Type: application/json"},
    });
}

// Use OpenAI API to get response
fn query_openai(allocator: std.mem.Allocator, baseurl: []const u8, token: []const u8, model: []const u8, system_msg: []const u8, query: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(allocator, 
        "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"system\",\"content\":\"{s}\"}},{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", 
        .{model, system_msg, query});
    defer allocator.free(body);

    const auth_header = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth_header);

    const response = try curlRequest(allocator, .{
        .method = "POST",
        .url = baseurl,
        .body = body,
        .headers = &[_][]const u8{
            "Content-Type: application/json",
            auth_header,
        },
    });
    defer allocator.free(response);

    // Extract content from API response
    const content_prefix = "\"content\":\"";
    if (std.mem.indexOf(u8, response, content_prefix)) |content_start| {
        const start_idx = content_start + content_prefix.len;
        var end_idx = start_idx;
        var escaped = false;
        
        // Find the closing quote, handling escaped quotes
        while (end_idx < response.len) {
            if (response[end_idx] == '\\') {
                escaped = !escaped;
            } else if (response[end_idx] == '"' and !escaped) {
                break;
            } else {
                escaped = false;
            }
            end_idx += 1;
        }
        
        if (end_idx < response.len) {
            return try allocator.dupe(u8, response[start_idx..end_idx]);
        }
    }

    return error.InvalidResponse;
}

// HTTP Request options
const RequestOptions = struct {
    method: []const u8,
    url: []const u8,
    body: ?[]const u8,
    headers: []const []const u8,
};

// Execute HTTP request using curl command
fn curlRequest(allocator: std.mem.Allocator, options: RequestOptions) ![]const u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    defer args.deinit();

    try args.append("curl");
    try args.append("-s"); // Silent mode
    try args.append("-X");
    try args.append(options.method);
    
    // Add headers
    for (options.headers) |header| {
        try args.append("-H");
        try args.append(header);
    }
    
    // Add body if present
    if (options.body) |body| {
        try args.append("-d");
        try args.append(body);
    }
    
    // Add URL (must be last)
    try args.append(options.url);
    
    // Create a child process for curl
    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    // Read stdout
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024); // 1MB limit
    
    // Wait for process to complete
    const term = try child.wait();
    
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("curl exited with code {d}\n", .{code});
                allocator.free(stdout);
                return error.CurlFailure;
            }
        },
        else => {
            std.debug.print("curl terminated abnormally\n", .{});
            allocator.free(stdout);
            return error.CurlFailure;
        },
    }
    
    return stdout;
}