# Common Role

## Purpose

Configures the base operating system for all Ubuntu servers.

## Responsibilities

- Update APT package cache
- Upgrade installed packages
- Install common utilities
- Configure system timezone
- Enable unattended security upgrades

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `common_timezone` | `UTC` | System timezone |

## Example

```yaml
roles:
  - common
```

## Notes

This role should be executed before all other roles because it prepares the operating system.
