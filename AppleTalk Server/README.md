# AppleTalk Server Setup for Raspberry Pi

Configure Raspberry Pi as an AppleTalk file server and LaserWriter 8 compatible PostScript RIP print server for vintage Apple computers.

## Compatibility

**File Server:**
- Apple IIgs (GS/OS)
- Macintosh System 6.0.x
- Macintosh System 7.x
- Mac OS 8.x and 9.x

**Print Server:**
- Macintosh System 6.x with LaserWriter driver
- Macintosh System 7.x with LaserWriter 8 driver
- Mac OS 8.x and 9.x with LaserWriter 8

## Quick Start

1. Copy all scripts to your Raspberry Pi
2. Make them executable (if needed):
   ```bash
   chmod +x appletalk-server-setup.sh setup-fileserver.sh setup-printserver.sh
   ```
3. Run the main setup script:
   ```bash
   sudo ./appletalk-server-setup.sh
   ```

## Scripts

### `appletalk-server-setup.sh`
Main control script that guides you through the setup process. Allows you to choose:
- File server only (recommended first)
- Print server only
- Both servers

### `setup-fileserver.sh`
Installs and configures:
- Netatalk 2.2.4 (compiled from source for optimal compatibility)
- AppleTalk networking (EtherTalk Phase 2)
- AFP (Apple Filing Protocol) daemon
- Avahi for network discovery
- Shared folders configuration

### `setup-printserver.sh`
Installs and configures:
- CUPS print system
- Ghostscript for PostScript RIP
- LaserWriter 8 compatible PPD
- Network printing (IPP, socket, LPD)
- AppleTalk PAP (Printer Access Protocol) if Netatalk is installed
- PostScript MIME type handling for vintage Mac formats

## Installation Order

**Recommended:** Install file server first, then print server if needed.

The print server requires Netatalk for AppleTalk printer support. If you run the print server setup without Netatalk installed, it will offer to run the file server setup first.

## File Server Features

- **AppleTalk networking:** Full Phase 2 EtherTalk support
- **AFP file sharing:** Compatible with System 6 through OS 9
- **Guest access:** Optional password-free sharing
- **User authentication:** Support for password-protected volumes
- **Automatic discovery:** Appears in Chooser automatically

### Default Shares

By default, the setup creates:
- `Shared` - A public folder at `/home/pi/Shared` (optional)
- `Home` - The user's home directory (optional)
- `Pi` - The pi user's directory (optional)

### Adding Custom Shares

Edit `/usr/local/etc/netatalk/AppleVolumes.default` (or `/etc/netatalk/AppleVolumes.default`):

```
/path/to/folder "Volume Name" options:upriv,usedots
```

Then restart netatalk:
```bash
sudo systemctl restart netatalk
```

## Print Server Features

- **PostScript RIP:** Converts PostScript to raster using Ghostscript
- **LaserWriter 8 compatible:** Handles vintage Mac PostScript output
- **Multiple protocols:**
  - AppleTalk PAP (for System 6/7)
  - IPP (Internet Printing Protocol)
  - Socket printing (port 9100)
  - LPD (Line Printer Daemon)
- **Mac binary PostScript:** Automatically handles Mac-specific PostScript headers
- **Network printing:** Accessible from modern Macs too

### Connecting from System 6/7

1. Open **Chooser**
2. Click **LaserWriter** or **LaserWriter 8** icon
3. Ensure AppleTalk is **Active**
4. Select your printer from the list
5. Click **Setup** or **Select**

### Connecting from Modern Macs

1. System Preferences → Printers & Scanners
2. Click **+** to add printer
3. Click **IP** tab
4. Enter server IP address
5. Protocol: **Internet Printing Protocol - IPP**
6. Queue: `printers/PrinterName`

## Troubleshooting

### File Server

Check service status:
```bash
sudo systemctl status netatalk
```

View logs:
```bash
sudo journalctl -u netatalk -f
```

Check AppleTalk devices:
```bash
sudo nbplookup
```

Restart service:
```bash
sudo systemctl restart netatalk
```

### Print Server

Check CUPS status:
```bash
sudo systemctl status cups
```

View print queue:
```bash
lpstat -t
```

View CUPS logs:
```bash
sudo tail -f /var/log/cups/error_log
```

Test printing:
```bash
echo '%!PS' | lp -d PrinterName
```

### Common Issues

**Server doesn't appear in Chooser:**
- Wait 30-60 seconds for network discovery
- Check that AppleTalk is "Active" in Chooser
- Verify netatalk is running: `sudo systemctl status netatalk`
- Check network connection

**Printer doesn't appear:**
- Verify netatalk is running with PAP enabled
- Check papd.conf: `cat /usr/local/etc/netatalk/papd.conf`
- Look for printer in CUPS: `lpstat -p`
- Check AppleTalk: `nbplookup`

**Print jobs don't complete:**
- Check CUPS error log: `sudo tail -f /var/log/cups/error_log`
- Verify printer is accepting jobs: `lpstat -p`
- Test Ghostscript: `gs -dBATCH -dNOPAUSE -sDEVICE=cups -sOutputFile=/tmp/test.out /usr/share/cups/data/testprint`

## Configuration Files

### File Server
- Main config: `/usr/local/etc/netatalk/` or `/etc/netatalk/`
- AppleTalk: `atalkd.conf`
- AFP daemon: `afpd.conf`
- Shared volumes: `AppleVolumes.default`

### Print Server
- CUPS config: `/etc/cups/cupsd.conf`
- MIME types: `/etc/cups/mime.types`
- MIME conversions: `/etc/cups/mime.convs`
- LaserWriter PPD: `/usr/share/ppd/custom/LaserWriter8.ppd`
- PostScript filter: `/usr/lib/cups/filter/pstoraster`
- PAP config: `/usr/local/etc/netatalk/papd.conf` (if netatalk installed)

## Backups

All scripts create timestamped backups of configuration files before modifying them:
- `filename.bak.YYYYMMDD_HHMMSS`

To restore from backup:
```bash
sudo cp /path/to/file.bak.20240101_120000 /path/to/file
sudo systemctl restart netatalk  # or cups
```

## Network Information

Find your Raspberry Pi's network details:
```bash
hostname          # Display hostname
hostname -I       # Display IP address
```

## Requirements

- Raspberry Pi
- Raspbian - lite version (no GUI) recommended
- Internet connection (for downloading Netatalk 2.2.4 source)
- Network connection to vintage Macs/Apple IIgs

## Notes

- **Netatalk 2.2.4** is compiled from source for maximum compatibility
- The file server setup takes 5-10 minutes (compilation time)
- Print server setup is much faster (2-3 minutes)
- All services start automatically on boot
- Configuration is preserved across reboots

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review system logs: `sudo journalctl -u netatalk -n 50`
3. Check CUPS logs: `sudo tail -f /var/log/cups/error_log`
