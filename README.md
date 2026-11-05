# Auto Heat and Cool Seats (HMG-API mod)

When the car starts, this checks the outside temperature and turns on what you picked:

- **Below the cold limit:** seat heaters and steering wheel heat.
- **Above the hot limit:** seat coolers.

It's the HMG-API version of [Cold-start Heat](https://github.com/eclipseempire/hkmc-coldstart-heat)
by eclipseempire, with seat cooling and rear seats added.

**[Download the latest release](https://github.com/dibble9012/auto-heat-and-cool-seats/releases/latest)**

Tested on a 2023 Kia EV6 GT-Line (USA), firmware 260507, with HMG-API 1.0.0.

## Install

You need HMG-API 1.0.0 or later on the car first. Both methods use a USB flash drive. Download
the file for your method from the
[latest release](https://github.com/dibble9012/auto-heat-and-cool-seats/releases/latest), listed
under **Assets**.

ADB over USB has to be off, or the port can't read the drive.

### With the HMG-API app

1. Download `auto-heat-and-cool-seats-v1.0-hmgapi-usb.zip`.
2. Unzip it onto the top level of a FAT32 flash drive, so the drive has
   `HMGAPI/updates/auto-heat-and-cool-seats-v1.0.zip`.
3. Plug the drive into the car and install the mod from the updates page in the HMG-API app.
4. Tap **Apply changes** in the app.

To remove the mod, use the HMG-API app.

### With NEMESIS

1. Download `auto-heat-and-cool-seats-v1.0-nemesis-usb.zip`.
2. Unzip it onto the top level of a FAT32 or exFAT flash drive, so the drive has `NEMESIS.data`
   and the `packages` folder at its top level. Keep only one NEMESIS package on the drive.
3. Once Android is up, plug the drive into the car and confirm the install of
   "Auto Heat and Cool Seats".
4. Restart the head unit if it asks, then take the drive out.

HMG-API installs and applies the mod for you. To remove it, uninstall the package in NEMESIS
Manager.

## Settings (HMG-API app)

| Setting | Default |
|---|---|
| Unit for the limits (Fahrenheit or Celsius) | Fahrenheit |
| Cold limit | 50 |
| Hot limit | 85 |
| Steering wheel heat when it's cold | on |
| Heat level for driver and passenger (off, low, medium, high) | driver medium, passenger off |
| Heat level for rear left and rear right (off, low, high) | off |
| Cooling level for driver and passenger (off, low, medium, high) | driver medium, passenger off |

A temperature exactly on a limit does nothing. Changes count from the next start.

The first time the mod sends a command, HMG-API asks on screen whether to allow it. There's
one question each for seat heat, seat cooling and wheel heat. The mod keeps trying for a
minute while a question is up, so the first start can look slow. After that, the question
comes back at the next start that needs it.

## How it works

- A start is `hv.ready` turning 1, checked every 3 seconds. Accessory power alone doesn't
  count. One read of the car being off is enough for the next READY to be a new start. The
  mod also catches a head unit that boots after the car is READY, or that wakes from sleep
  (a jump in `/proc/uptime`).
- It takes `outside_temp_f` or `outside_temp`, waiting as long as the car stays on for a first
  value. With no sensible value, it does nothing.
- It sends `seat_heat`, `seat_vent` and `wheel_heat` through `hmgapid vehicle-do`. HMG-API
  calls the car's methods by name, so the mod has no service numbers of its own.
- It leaves a seat alone if it's already heating or cooling, and doesn't touch the wheel if
  it's already on.
- If the car doesn't show a change, the mod sends it again every 3 seconds for up to a minute.
  It stops once the car shows the change or turns off.
- If the car is already moving at READY and the head unit has been up for 3 minutes or more,
  it does nothing, so a service restart mid-drive won't turn back on something you turned off.
  Within 3 minutes of the head unit booting, it still applies, because you may have driven off
  before the unit finished booting. A head unit reboot mid-drive counts as a start.
- `hmgapid vehicle` answers at once but then waits 3 seconds to finish, holding one of the 8
  workers all mods share. The mod reads everything it needs in one background call and takes
  just the answer, so the wait doesn't slow it or tie up more workers.

The log is at `/data/hmgapi/logs/auto-heat-and-cool-seats/seats.log`. On the car,
`sh seats.sh check [temp]` prints what the mod would do and sends nothing.

## Build

You need a checkout of [HMG-API](https://github.com/VysseCodes/HMG-API), whose
`tools/mknemesismod.sh` makes the NEMESIS package.

```bash
./build.py ~/.hmgapi/author.key ../HMG-API
```

This writes the two release files to `dist/`, along with
`auto-heat-and-cool-seats-v1.0.hmgapi.zip`, the signed mod inside them. Updates must be signed
with the same key as the first install.

## Test

```bash
test/run.sh
```

This runs the script off the car under bash, with a fake `hmgapid` and `sleep`.

## License

AGPL-3.0. See [LICENSE](LICENSE).
