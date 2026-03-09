# Debugging RC services at boot (modloop, k3s-modules, cgroups, k3s-server)

## 1. OpenRC boot log

With `rc_logger="YES"` in `/etc/rc.conf` (set by install.sh), OpenRC writes startup output to:

```text
/var/log/rc.log
```

After boot, on the Pi:

```bash
cat /var/log/rc.log
```

You’ll see which runlevels ran (sysinit, boot, default) and which services were started or failed.

## 2. Check what’s enabled and what ran

```bash
# Services enabled in each runlevel
rc-update show -v

# Current runlevel and service state
rc-status

# Only boot runlevel
rc-status boot

# Single service
rc-service modloop status
```

## 3. Try starting modloop by hand

```bash
# Start and watch output
rc-service modloop start

# Or run the script directly to see errors
/etc/init.d/modloop start
```

If it works here but not at boot, compare with `rc.log` to see if modloop is never started or if it’s started and then fails.

## 4. Run boot runlevel again (after boot)

```bash
# Re-run boot runlevel (modloop, k3s-modules, cgroups, etc.)
openrc boot
```

Then check `rc-status` and `/var/log/rc.log` again.

## 5. Serial console / kernel cmdline

If you have serial (e.g. UART), remove `quiet` from the kernel cmdline to see kernel and early init messages. Boot messages may also appear on the console before SSH is up.

## 6. Why services might not start at boot

- **Runlevels not run**: init may only run `sysinit` and not `boot`/`default` (e.g. diskless with apkovl). Check `rc.log` for “Entering runlevel boot” / “Entering runlevel default”.
- **modloop missing**: `rc-update add modloop boot` is no-op if `/etc/init.d/modloop` doesn’t exist. On the Pi: `ls -la /etc/init.d/modloop`.
- **Dependencies**: modloop/k3s-modules/cgroups have `need localmount` (and each other). If something in that chain fails, later services won’t start; failures should appear in `rc.log`.
