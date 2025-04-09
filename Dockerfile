# Use a minimal base image and install Zig manually
FROM debian:bullseye-slim as build

# Install dependencies
RUN apt-get update && apt-get install -y wget tar xz-utils build-essential curl && rm -rf /var/lib/apt/lists/*

# Install Zig
WORKDIR /zig
RUN wget https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz \
    && tar -xf zig-linux-x86_64-0.11.0.tar.xz \
    && mv zig-linux-x86_64-0.11.0 /usr/local/zig \
    && ln -s /usr/local/zig/zig /usr/bin/zig

# Set the working directory
WORKDIR /app

# Copy the project files into the container
COPY . .

# Build the Zig application
RUN zig build

# Use a minimal base image for the final container
FROM debian:bullseye-slim

# Install curl for HTTP requests
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy the built binary from the build stage
COPY --from=build /app/zig-out/bin/zigExampleBot /app/zigExampleBot

# Expose the port the bot will use (if applicable)
EXPOSE 8080

# Command to run the bot
CMD ["/app/zigExampleBot"]