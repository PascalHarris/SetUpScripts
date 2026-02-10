/*
 * Debug.h
 * Simple file-based debug logging system for Classic Mac OS
 * 
 * Usage:
 *   DebugInit("myapp.log");           // Initialize at startup
 *   DebugLog("Something happened");   // Write a log message
 *   DebugLogInt("Value: ", 42);       // Log with integer
 *   DebugClose();                     // Close at shutdown
 *
 * Copyright © 2026 Pascal Harris. All rights reserved.
 */

#ifndef DEBUG_H
#define DEBUG_H

#ifndef __TYPES__
#include <Types.h>
#endif

/*
 * DebugInit
 * Initialize the debug log file. Creates/overwrites the file.
 * Call this once at application startup.
 * 
 * filename: Name of log file (e.g., "debug.txt" or "innecto.log")
 * Returns: true if successful, false if file couldn't be created
 */
Boolean DebugInit(const char *filename);

/*
 * DebugLog
 * Write a simple text message to the log file.
 * Automatically adds newline and timestamp.
 * 
 * message: Text to write to log
 */
void DebugLog(const char *message);

/*
 * DebugLogInt
 * Write a message with an integer value.
 * 
 * message: Text prefix (e.g., "Count: ")
 * value: Integer to log
 */
void DebugLogInt(const char *message, long value);

/*
 * DebugLogHex
 * Write a message with a hex value.
 * 
 * message: Text prefix (e.g., "Connections: ")
 * value: Value to display as hex
 */
void DebugLogHex(const char *message, unsigned long value);

/*
 * DebugLogFormat
 * Write a formatted message (like printf).
 * Automatically adds newline.
 * 
 * format: printf-style format string
 * ...: Variable arguments
 */
void DebugLogFormat(const char *format, ...);

/*
 * DebugFlush
 * Force all buffered log data to be written to disk.
 * Useful before potential crashes or at critical points.
 */
void DebugFlush(void);

/*
 * DebugClose
 * Close the debug log file.
 * Call this at application shutdown.
 */
void DebugClose(void);

/*
 * DebugIsEnabled
 * Check if debug logging is currently enabled.
 * Returns: true if log file is open and ready
 */
Boolean DebugIsEnabled(void);

#endif /* DEBUG_H */
