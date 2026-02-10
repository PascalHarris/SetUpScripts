/*
 * Debug.c
 * Bulletproof debug logging for Classic Mac OS
 * Uses explicit error checking and minimal dependencies
 *
 * Copyright © 2026 Pascal Harris. All rights reserved.
 */

#include "Debug.h"
#include <Files.h>

/* Private state */
static short gDebugRefNum = 0;
static Boolean gDebugEnabled = false;

/* Simple strlen replacement to avoid library issues */
static short MyStrLen(const char *str)
{
    short len = 0;
    if (str == nil) return 0;
    while (*str != '\0' && len < 32000) {
        len++;
        str++;
    }
    return len;
}

/*
 * DebugInit
 * Initialize the debug log file.
 */
Boolean DebugInit(const char *filename)
{
    unsigned char pFilename[256];
    OSErr err;
    short len;
    long count;
    const char *headerMsg = "DEBUG LOG INITIALIZED\r";
    
    /* Close existing log if open */
    if (gDebugRefNum != 0) {
        FSClose(gDebugRefNum);
        gDebugRefNum = 0;
    }
    
    gDebugEnabled = false;
    
    /* Safety check */
    if (filename == nil) {
        SysBeep(1); /* Beep: filename is nil */
        return false;
    }
    
    /* Convert C string to Pascal string manually */
    len = MyStrLen(filename);
    if (len > 255) len = 255;
    pFilename[0] = (unsigned char)len;
    {
        short i;
        for (i = 0; i < len; i++) {
            pFilename[i + 1] = filename[i];
        }
    }
    
    /* Delete old file (ignore errors) */
    FSDelete(pFilename, 0);
    
    /* Create the file */
    err = Create(pFilename, 0, 'ttxt', 'TEXT');
    if (err != noErr) {
        SysBeep(2); /* Beep: Create failed */
        return false;
    }
    
    /* Open the file */
    err = FSOpen(pFilename, 0, &gDebugRefNum);
    if (err != noErr) {
        SysBeep(3); /* Beep: FSOpen failed */
        gDebugRefNum = 0;
        return false;
    }
    
    /* Enable debug logging */
    gDebugEnabled = true;
    
    /* Write header */
    count = MyStrLen(headerMsg);
    err = FSWrite(gDebugRefNum, &count, headerMsg);
    if (err != noErr) {
        SysBeep(4); /* Beep: FSWrite failed */
        FSClose(gDebugRefNum);
        gDebugRefNum = 0;
        gDebugEnabled = false;
        return false;
    }
    
    /* Success beep */
    SysBeep(10);
    return true;
}

/*
 * DebugLog
 * Write a simple text message to the log.
 */
void DebugLog(const char *message)
{
    long count;
    OSErr err;
    const char newline = '\r';
    short msgLen;
    
    /* Immediate safety checks */
    if (!gDebugEnabled) {
        SysBeep(5); /* Not enabled */
        return;
    }
    
    if (gDebugRefNum == 0) {
        SysBeep(6); /* No file ref */
        return;
    }
    
    if (message == nil) {
        SysBeep(7); /* Nil message */
        return;
    }
    
    /* Get message length */
    msgLen = MyStrLen(message);
    if (msgLen == 0) {
        SysBeep(8); /* Empty message */
        return;
    }
    
    /* Write message */
    count = msgLen;
    err = FSWrite(gDebugRefNum, &count, message);
    if (err != noErr || count != msgLen) {
        SysBeep(20); /* Write failed */
        return;
    }
    
    /* Write newline */
    count = 1;
    err = FSWrite(gDebugRefNum, &count, &newline);
    if (err != noErr) {
        SysBeep(21); /* Newline write failed */
        return;
    }
    
    /* Success - no beep */
}

/*
 * DebugLogInt
 * Write a message with an integer value.
 */
void DebugLogInt(const char *message, long value)
{
    char numBuf[20];
    short i = 0;
    short j;
    long count;
    OSErr err;
    unsigned long absVal;
    Boolean isNeg = false;
    const char newline = '\r';
    short msgLen;
    
    if (!gDebugEnabled || gDebugRefNum == 0 || message == nil) {
        return;
    }
    
    /* Write message part */
    msgLen = MyStrLen(message);
    if (msgLen > 0) {
        count = msgLen;
        err = FSWrite(gDebugRefNum, &count, message);
        if (err != noErr) return;
    }
    
    /* Convert number to string */
    if (value < 0) {
        isNeg = true;
        absVal = -value;
    } else {
        absVal = value;
    }
    
    /* Build digits in reverse */
    if (absVal == 0) {
        numBuf[i++] = '0';
    } else {
        while (absVal > 0 && i < 19) {
            numBuf[i++] = '0' + (absVal % 10);
            absVal /= 10;
        }
    }
    
    if (isNeg) {
        numBuf[i++] = '-';
    }
    
    /* Write digits in correct order */
    for (j = i - 1; j >= 0; j--) {
        count = 1;
        err = FSWrite(gDebugRefNum, &count, &numBuf[j]);
        if (err != noErr) return;
    }
    
    /* Write newline */
    count = 1;
    err = FSWrite(gDebugRefNum, &count, &newline);
}

/*
 * DebugLogHex
 * Write a message with a hex value.
 */
void DebugLogHex(const char *message, unsigned long value)
{
    char hexBuf[16];
    short i;
    long count;
    OSErr err;
    const char newline = '\r';
    const char hexChars[] = "0123456789ABCDEF";
    short msgLen;
    
    if (!gDebugEnabled || gDebugRefNum == 0 || message == nil) {
        return;
    }
    
    /* Write message */
    msgLen = MyStrLen(message);
    if (msgLen > 0) {
        count = msgLen;
        FSWrite(gDebugRefNum, &count, message);
    }
    
    /* Write "0x" */
    hexBuf[0] = '0';
    hexBuf[1] = 'x';
    count = 2;
    FSWrite(gDebugRefNum, &count, hexBuf);
    
    /* Write hex digits (2 digits for byte value) */
    hexBuf[0] = hexChars[(value >> 4) & 0x0F];
    hexBuf[1] = hexChars[value & 0x0F];
    count = 2;
    FSWrite(gDebugRefNum, &count, hexBuf);
    
    /* Write newline */
    count = 1;
    FSWrite(gDebugRefNum, &count, &newline);
}

/*
 * DebugLogFormat
 * Not fully implemented - just logs the format string
 */
void DebugLogFormat(const char *format, ...)
{
    if (format != nil) {
        DebugLog(format);
    }
}

/*
 * DebugFlush
 * No-op for Mac file I/O
 */
void DebugFlush(void)
{
}

/*
 * DebugClose
 * Close the debug log file.
 */
void DebugClose(void)
{
    long count;
    const char *endMsg = "DEBUG LOG CLOSED\r";
    
    if (gDebugRefNum != 0) {
        count = MyStrLen(endMsg);
        FSWrite(gDebugRefNum, &count, endMsg);
        FSClose(gDebugRefNum);
        gDebugRefNum = 0;
    }
    
    gDebugEnabled = false;
}

/*
 * DebugIsEnabled
 * Check if debug logging is active.
 */
Boolean DebugIsEnabled(void)
{
    return gDebugEnabled;
}
