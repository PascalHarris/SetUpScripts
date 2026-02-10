# Debug System User Guide
## Classic Macintosh File Logging for Think C

### Overview

Debug.c and Debug.h provide a simple, reliable file-based logging system for Classic Macintosh applications built with Think C. The system writes human-readable log files that can be examined after your programme runs, making it an essential tool for debugging issues that only manifest on physical hardware.

---

## Installation

### Adding to Your Think C Project

1. **Add the files to your project:**
   - Copy `Debug.h` and `Debug.c` to your project folder
   - In Think C, choose **Project → Add…**
   - Select `Debug.c` and add it to your project
   - `Debug.h` will be found automatically when included

2. **Required includes:**

   ```c
   #include "Debug.h"
   ```
   
   That's all you need. The Debug system handles its own dependencies internally.

3. **No additional libraries required:**
   - Uses only Mac Toolbox file I/O (Files.h)
   - No ANSI C library dependencies
   - No special compiler flags needed

---

## Basic Usage

### Minimal Example

```c
#include "Debug.h"

void main(void)
{
    /* Initialise debug logging */
    DebugInit("myapp.log");
    
    /* Write some messages */
    DebugLog("Application started");
    DebugLog("Processing data...");
    
    /* Close the log */
    DebugClose();
}
```

This creates a file called `myapp.log` in the same folder as your application.

---

## API Reference

### DebugInit()
**Purpose:** Initialise the debug log file. Call this once at application startup.

**Signature:**

```c
Boolean DebugInit(const char *filename);
```

**Parameters:**

- `filename` - Name of the log file (e.g., `"debug.txt"`, `"myapp.log"`)

**Returns:**

- `true` if successful
- `false` if the file couldn't be created

**Behaviour:**

- Creates a new log file (overwrites existing file with same name)
- Writes a header message
- Emits a system beep (pitch 10) on success

**Example:**

```c
if (DebugInit("innecto.log")) {
    DebugLog("Debug system initialised successfully");
} else {
    /* Handle error - file couldn't be created */
    SysBeep(1);
}
```

**Best Practice:**

Always check the return value. If it returns `false`, the debug system is disabled and subsequent calls will be safely ignored.

---

### DebugLog()
**Purpose:** Write a simple text message to the log.

**Signature:**

```c
void DebugLog(const char *message);
```

**Parameters:**

- `message` - Text string to write to the log

**Returns:** Nothing

**Behaviour:**

- Writes the message followed by a newline (`\r` in Mac text format)
- Safely handles `nil` pointers (no crash)
- Does nothing if debug system isn't initialised

**Example:**

```c
DebugLog("Entering critical section");
DebugLog("User clicked menu item");
DebugLog("Processing complete");
```

**Notes:**

- Each call writes a separate line
- Messages are written immediately (no buffering)
- Maximum message length: ~32,000 characters

---

### DebugLogInt()
**Purpose:** Write a message followed by an integer value.

**Signature:**

```c
void DebugLogInt(const char *message, long value);
```

**Parameters:**

- `message` - Text to write before the number
- `value` - Integer value to append (can be positive or negative)

**Returns:** Nothing

**Example:**

```c
DebugLogInt("Tile count: ", 64);
DebugLogInt("Move number: ", moveCount);
DebugLogInt("Error code: ", -1);
```

**Output:**

```
Tile count: 64
Move number: 42
Error code: -1
```

**Notes:**

- Handles negative numbers correctly
- No formatting options (always decimal)
- For hex values, use `DebugLogHex()` instead

---

### DebugLogHex()
**Purpose:** Write a message followed by a hexadecimal value.

**Signature:**

```c
void DebugLogHex(const char *message, unsigned long value);
```

**Parameters:**

- `message` - Text to write before the hex value
- `value` - Value to display in hexadecimal (only lowest byte used)

**Returns:** Nothing

**Example:**

```c
DebugLogHex("Connection byte: ", 0x0C);
DebugLogHex("Status: ", statusByte);
DebugLogHex("Flags: ", tile->connections);
```

**Output:**

```
Connection byte: 0x0C
Status: 0xFF
Flags: 0x3A
```

**Notes:**

- Always displays as 2-digit hex (e.g., `0x0C`, not `0xC`)
- Only uses the lowest 8 bits of the value
- Useful for bit fields, flags, and byte values

---

### DebugLogFormat()
**Purpose:** Write a formatted message (limited functionality).

**Signature:**

```c
void DebugLogFormat(const char *format, ...);
```

**Parameters:**

- `format` - Format string
- `...` - Variable arguments (currently ignored)

**Returns:** Nothing

**Current Behaviour:**

```c
DebugLogFormat("Value is %d", 42);
```

**Output:**

```
Value is %d
```

**Important:** 
This function currently only writes the format string itself, ignoring the arguments. It exists as a placeholder for future enhancement and to avoid breaking code that uses it.

**Workaround:**
For formatted output, use multiple calls:

```c
DebugLog("Processing tile:");
DebugLogInt("  Row: ", row);
DebugLogInt("  Column: ", col);
DebugLogHex("  Connections: ", connections);
```

---

### DebugFlush()
**Purpose:** Force buffered data to be written to disk.

**Signature:**

```c
void DebugFlush(void);
```

**Returns:** Nothing

**Note:** This function is a no-op. Mac Toolbox file I/O writes data immediately, so there's nothing to flush. It exists for compatibility with other logging systems.

---

### DebugClose()
**Purpose:** Close the debug log file. Call this at application shutdown.

**Signature:**
```c
void DebugClose(void);
```

**Returns:** Nothing

**Behaviour:**
- Writes a footer message
- Closes the log file
- Disables the debug system

**Example:**
```c
void CleanupApp(void)
{
    /* Clean up other resources */
    DisposeWindow(gMainWindow);
    
    /* Close debug log last */
    DebugClose();
}
```

**Best Practice:**
Call this as the very last thing before your programme exits. This ensures all log messages are written before the file is closed.

---

### DebugIsEnabled()
**Purpose:** Check if the debug system is currently active.

**Signature:**
```c
Boolean DebugIsEnabled(void);
```

**Returns:**
- `true` if debug logging is active
- `false` if not initialised or has been closed

**Example:**
```c
if (DebugIsEnabled()) {
    DebugLog("This will be logged");
}
```

**Note:** You don't need to check this before calling debug functions - they safely do nothing if debug is disabled. This is mainly useful for conditional debug code.

---

## Complete Example

```c
#include "Innecto.h"
#include "Debug.h"

void main(void)
{
    Boolean debugActive;
    
    /* Initialise Mac Toolbox */
    InitToolbox();
    
    /* Initialise debug logging */
    debugActive = DebugInit("innecto_debug.txt");
    
    if (debugActive) {
        DebugLog("=== Innecto Started ===");
        DebugLogInt("System version: ", SysEnvirons.systemVersion);
    }
    
    /* Initialise application */
    InitApp();
    DebugLog("InitApp() completed");
    
    /* Main event loop */
    DebugLog("Entering event loop");
    EventLoop();
    DebugLog("Event loop exited");
    
    /* Clean up */
    DebugLog("Shutting down");
    CleanupApp();
    
    /* Close debug log */
    DebugClose();
}
```

---

## Best Practises

### 1. Initialise Early
Call `DebugInit()` as early as possible in your programme, right after Toolbox initialisation:

```c
void main(void)
{
    InitToolbox();
    DebugInit("debug.txt");  /* Do this early */
    /* ... rest of initialisation */
}
```

### 2. Close Late
Call `DebugClose()` as the very last thing before exiting:

```c
void CleanupApp(void)
{
    /* Clean up all resources first */
    DisposeWindow(gMainWindow);
    UnloadPatterns();
    
    DebugClose();  /* Do this last */
}
```

### 3. Use Descriptive Messages
Write messages that clearly indicate what's happening:

**Good:**

```c
DebugLog(">>> TileRotateLeft() called");
DebugLogHex("  Old connections: ", oldConn);
DebugLogHex("  New connections: ", newConn);
DebugLog("  Animation started");
```

**Poor:**

```c
DebugLog("here");
DebugLogInt("x", x);
```

### 4. Use Indentation for Context
Indent related messages to show hierarchy:

```c
DebugLog("Starting level generation");
DebugLogInt("  Grid size: ", gridSize);
DebugLogInt("  Difficulty: ", difficulty);
DebugLog("  Generating tiles...");
DebugLog("  Calculating connections...");
DebugLog("Level generation complete");
```

### 5. Log State Transitions
Track important state changes:

```c
void TileStartRotation(YANTile *tile, unsigned char newConn)
{
    DebugLog(">>> TileStartRotation");
    DebugLogHex("  displayConn: ", tile->displayConnections);
    DebugLogHex("  targetConn: ", newConn);
    
    /* ... rotation code ... */
    
    DebugLog("<<< TileStartRotation complete");
}
```

### 6. Use Markers for Important Events
Use distinctive markers for key events:

```c
DebugLog("========================================");
DebugLog("USER CLICKED TILE");
DebugLog("========================================");
```

### 7. Conditional Debug Code
Use preprocessor directives for debug-only code:

```c
#define DEBUG_ENABLED 1

void GameHandleTileClick(YANTile *tile)
{
    #if DEBUG_ENABLED
    DebugLog("Tile clicked");
    DebugLogInt("  Tile index: ", tile->index);
    #endif
    
    /* Normal game code */
    TileRotate(tile);
}
```

### 8. Don't Log Too Much
Balance detail with readability. Logging every single function call creates noise:

**Good:**

```c
/* Log significant events */
DebugLog("Animation started");
DebugLog("Animation completed");
```

**Poor:**

```c
/* Too much detail */
DebugLog("Entering function");
DebugLog("Checking parameter");
DebugLog("Parameter valid");
DebugLog("Allocating memory");
DebugLog("Memory allocated");
/* ... 50 more lines ... */
```

### 9. Use Consistent Prefixes
Adopt a convention for different types of messages:

```c
DebugLog(">>> Function entry");     /* Function start */
DebugLog("<<< Function exit");      /* Function end */
DebugLog("!!! ERROR occurred");     /* Error condition */
DebugLog("??? Unexpected state");   /* Warning */
DebugLog("=== Major milestone");   /* Important event */
```

### 10. Check File Location
The log file is created in the **same folder as your application**. If you can't find it:
- Use Find File (⌘F) to search for the filename
- Check if it's in the System Folder
- Try using an absolute path: `DebugInit(":MyFolder:debug.txt")`

---

## File Format

Debug log files use standard Macintosh text format:

- **Line endings:** CR (`\r`, ASCII 13), not LF (`\n`)
- **File type:** 'TEXT'
- **Creator:** 'ttxt' (SimpleText/TeachText)

You can open log files with:
- SimpleText
- TeachText
- BBEdit
- Any Mac text editor

---

## Troubleshooting

### No Log File Created

**Symptom:** `DebugInit()` returns `false`, no log file appears

**Solutions:**

- Check you have write permission in the folder
- Ensure sufficient disk space
- Try a different folder (e.g., Desktop)
- Use Find File to search for the filename

### Log File Truncated

**Symptom:** Log file exists but ends abruptly

**Cause:** Application crashed after writing some messages

**Solution:** The last message in the log shows you where the crash occurred. This is actually very useful information!

### Messages Not Appearing

**Symptom:** `DebugInit()` succeeds but some messages are missing

**Check:**

- Are you calling `DebugLog()` before `DebugInit()`? (Won't work)
- Did you call `DebugClose()` too early? (Stops logging)
- Is the debug code inside a `#if` block that's set to 0?

---

## Performance Considerations

### Overhead
- Each `DebugLog()` call performs a file write operation
- File I/O is relatively slow on vintage Macs
- Not suitable for logging inside tight loops

### Best Practise for Performance-Critical Code

**Don't do this:**

```c
/* BAD - logs 1000 times per frame */
for (i = 0; i < 1000; i++) {
    DebugLogInt("Processing item: ", i);
    ProcessItem(i);
}
```

**Do this instead:**

```c
/* GOOD - logs once per frame */
DebugLogInt("Processing items, count: ", itemCount);
for (i = 0; i < 1000; i++) {
    ProcessItem(i);
}
DebugLog("Processing complete");
```

### Conditional Compilation
For production builds, disable debug logging entirely:

```c
#define DEBUG_ENABLED 0

#if DEBUG_ENABLED
    DebugInit("debug.txt");
    DebugLog("Debug message");
    DebugClose();
#endif
```

The compiler will optimise out all the debug code, resulting in zero overhead.

---

## Advanced Usage

### Multiple Log Files
You can't have multiple log files open simultaneously, but you can close and reopen:

```c
DebugInit("startup.log");
DebugLog("Application starting");
DebugClose();

/* Later... */

DebugInit("gameplay.log");
DebugLog("Game started");
DebugClose();
```

### Timestamping
The debug system doesn't include timestamps, but you can add them manually:

```c
void LogWithTime(const char *message)
{
    unsigned long ticks = TickCount();
    DebugLogInt("[Tick ", ticks);
    DebugLog("] ");
    DebugLog(message);
}
```

### Hex Dumps
For debugging binary data:

```c
void LogHexDump(const char *label, unsigned char *data, short len)
{
    short i;
    
    DebugLog(label);
    for (i = 0; i < len; i++) {
        DebugLogHex("  ", data[i]);
    }
}
```

---

## Integration with Other Systems

### With SIOW (Symantec IDE Output Window)
If you're also using printf/SIOW for debugging:

```c
#define LOG_TO_FILE 1
#define LOG_TO_CONSOLE 1

void MyLog(const char *msg)
{
    #if LOG_TO_FILE
    DebugLog(msg);
    #endif
    
    #if LOG_TO_CONSOLE
    printf("%s\n", msg);
    #endif
}
```

### With MacsBug
Debug.c works alongside MacsBug. If you have MacsBug installed, you can use both:
- Debug.c for persistent logging
- MacsBug for interactive debugging

---

## Summary

**Essential calls:**

1. `DebugInit("logfile.txt")` - at startup
2. `DebugLog("message")` - whenever you need to log
3. `DebugClose()` - at shutdown

That's all you need to get started. 