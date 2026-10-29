# TechNexion Intel IPU7 Camera Deployment for Panther Lake

This repository builds and packages the Intel IPU7 camera stack and the
TechNexion Linux kernel for Panther Lake platforms.

The build process produces a self-contained deployment bundle containing:

- TechNexion Linux kernel Debian package
- Intel IPU7 camera userspace Debian package
- Target installation script

## Branches

| Branch | Camera configuration | Kernel overlay branch |
|---|---|---|
| `main` | Standard TechNexion Panther Lake build | `main` |
| `lexcom` | Lexcom-specific build | `lexcom` |
| `asus` | ASUS RUC-2000H GMSL port0/port1 | `asus` |

Kernel configurations and patches are provided by:

[TechNexion-Vision/tn-intel-linux-kernel-overlay](https://github.com/TechNexion-Vision/tn-intel-linux-kernel-overlay)

The matching kernel overlay branch is selected automatically by
`ptl-camera.sh`.

## Build Requirements

Use an Ubuntu x86-64 build host with:

- Git
- Docker
- Debian packaging tools
- Linux kernel build dependencies
- Sufficient disk space for a complete kernel build

The complete build can take a significant amount of time and disk space.

## Standard Build

```bash
git clone https://github.com/TechNexion-Vision/tn-intel-camera-deploy.git
cd tn-intel-camera-deploy
git switch main

./ptl-camera.sh --all
```

This builds the standard Panther Lake package using the `main` branch of
`tn-intel-linux-kernel-overlay`.

## Lexcom Build

Use a separate working directory to avoid mixing build outputs:

```bash
git clone --branch lexcom \
  https://github.com/TechNexion-Vision/tn-intel-camera-deploy.git \
  tn-intel-camera-deploy-lexcom

cd tn-intel-camera-deploy-lexcom
./ptl-camera.sh --all
```

This builds the Lexcom package using the `lexcom` branch of
`tn-intel-linux-kernel-overlay`.

## Build Process

With `--all`, `ptl-camera.sh` performs the following operations:

1. Clones the Intel IPU7 camera components and the matching kernel overlay.
2. Builds the camera userspace components in Docker.
3. Builds the TechNexion Linux kernel Debian package.
4. Creates the IPU7 camera userspace Debian package.
5. Creates the final deployment bundle.

Running `./ptl-camera.sh` without `--all` only rebuilds the camera package and
deployment bundle from an existing build tree.

## Output

After a successful build:

```text
ptl-camera-out/ipu7-camera-ptl.deb
ptl-camera-out/tn-camera-ptl.tar.gz
```

`tn-camera-ptl.tar.gz` is the final deployment bundle. It contains:

```text
tn-camera-ptl/
├── install.sh
├── ipu7-camera-ptl.deb
└── linux-image-*.deb
```

## Install on the Target

Copy the deployment bundle to the target:

```bash
scp ptl-camera-out/tn-camera-ptl.tar.gz <user>@<TARGET_IP>:~/
```

Log in to the target and install it:

```bash
ssh <user>@<TARGET_IP>
tar xf tn-camera-ptl.tar.gz
sudo ./tn-camera-ptl/install.sh
sudo reboot
```

After rebooting, the target loads the newly installed kernel and IPU7 camera
stack.

## Notes

- Do not reuse the same build directory between `main` and `lexcom`.
- Camera firmware is not included; the target operating system provides the
  required firmware.
- Upstream Intel camera components remain subject to their respective licenses.

## ASUS RUC-2000H GMSL settings

The `asus` branch installs Camera1 on CSI port0 and Camera2 on CSI port1.
Camera2 uses `max9x b` and Capture8..11; set its BIOS MIPI port to 1.
Use CPHY, two lanes, PPR value/unit 2/4 and Degree 0 for the tested wiring.

Build with the matching `asus` kernel overlay branch, which adds the
ASUS-specific GPIO PWDNB release before MAX9x probe. JSON changes alone
cannot fix a failed hardware probe. Both branches must be published before
a fresh clone can build this configuration.

Four Camera2 sensors probed; `vlsgm2-6` streamed 1280x720 UYVY with the GPIO
fix. Other Camera2 streams, simultaneous capture and suspend/resume remain
unverified. Kernel stop/close timeout messages are a separate open issue.
