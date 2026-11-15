# ps5ctl

A developer tool for Shimmer's PS5 Remote Play path, on chiaki-ng's full
libchiaki (including PSN hole-punching). It lets an agent check a console,
register it and test-stream without the app.

```sh
tools/ps5ctl/build.sh                         # → build.noindex/ps5ctl
build.noindex/ps5ctl status 192.168.1.20      # power state and running game
build.noindex/ps5ctl register-pin 192.168.1.20 12345678
build.noindex/ps5ctl stream 192.168.1.20 --seconds 10 --out /tmp/ps5.h265 --press down@3
build.noindex/ps5ctl stream 192.168.1.20 --seconds 2 --rest   # then put it in rest mode
build.noindex/ps5ctl wake 192.168.1.20
```

`devices` and `register` (PIN-less registration over PSN) need a PSN access
token. Secrets stay in the login keychain, under the account named by
`PS5CTL_PSN_ACCOUNT`:

| Item | Keychain service |
|---|---|
| PSN account ID (base64) | `PlayStation Network account ID` |
| PSN access token | `PSN access token` |
| Registration | `PS5 Remote Play registration` (account: the console's MAC) |

`stream` prints frames per second, lost frames, RTT and audio arrival gaps once
a second. Check `status` first: a session takes over the console's screen.
